module Bundler
  class InvalidRepository < StandardError ; end

  class Bundle
    attr_reader :path

    def initialize(path, bindir)
      FileUtils.mkdir_p(path)

      @path = Pathname.new(path)
      @bindir = Pathname.new(bindir)

      @cache_path = @path.join('cache')
      @cache = GemDirectorySource.new(:location => @cache_path)

      @specs_path = @path.join('specifications')
      @gems_path = @path.join('gems')
    end

    def install(dependencies, sources, options = {})
      # TODO: clean this up
      sources.each do |s|
        s.repository = self
        s.local = options[:cached]
      end

      source_requirements = {}
      dependencies = dependencies.map do |dep|
        source_requirements[dep.name] = dep.source if dep.source
        dep.to_gem_dependency
      end

      # Check to see whether the existing cache meets all the requirements
      begin
        valid = nil
        # valid = Resolver.resolve(dependencies, [source_index], source_requirements)
      rescue Bundler::GemNotFound
      end

      sources = only_local(sources) if options[:cached]

      # Check the remote sources if the existing cache does not meet the requirements
      # or the user passed --update
      if options[:update] || !valid
        Bundler.logger.info "Calculating dependencies..."
        bundle = Resolver.resolve(dependencies, [@cache] + sources, source_requirements)
        download(bundle, options)
        do_install(bundle, options)
        valid = bundle
      end

      generate_bins(valid, options)
      cleanup(valid, options)
      configure(valid, options)
    end

    def cache(*gemfiles)
      FileUtils.mkdir_p(@cache_path)
      gemfiles.each do |gemfile|
        Bundler.logger.info "Caching: #{File.basename(gemfile)}"
        FileUtils.cp(gemfile, @cache_path)
      end
    end

    def prune(dependencies, sources)
      sources.each do |s|
        s.repository = self
        s.local = true
      end

      sources = only_local(sources)
      bundle = Resolver.resolve(dependencies, [@cache] + sources)
      @cache.gems.each do |name, specs|
        specs.each do |spec|
          unless bundle.any? { |s| s.name == spec.name && s.version == spec.version }
            Bundler.logger.info "Pruning #{spec.name} (#{spec.version}) from the cache"
            FileUtils.rm @cache_path.join("#{spec.full_name}.gem")
          end
        end
      end
    end

    def gems
      source_index.gems.values
    end

    def outdated_gems
      source_index.outdated.sort
    end

    def source_index
      index = Gem::SourceIndex.from_gems_in(@specs_path)
      index.each { |n, spec| spec.loaded_from = @specs_path.join("#{spec.full_name}.gemspec") }
      index
    end

    def download_path_for(type)
      @repos[type].download_path_for
    end

  private

    def only_local(sources)
      sources.select { |s| s.can_be_local? }
    end

    def download(bundle, options)
      bundle.sort_by {|s| s.full_name.downcase }.each do |spec|
        next if options[:no_bundle].include?(spec.name)
        spec.source.download(spec)
      end
    end

    def do_install(bundle, options)
      bundle.each do |spec|
        next if options[:no_bundle].include?(spec.name)
        spec.loaded_from = @specs_path.join("#{spec.full_name}.gemspec")
        # Do nothing if the gem is already expanded
        next if @gems_path.join(spec.full_name).directory?

        case spec.source
        when GemSource, GemDirectorySource, SystemGemSource
          expand_gemfile(spec, options)
        else
          expand_vendored_gem(spec, options)
        end
      end
    end

    def generate_bins(bundle, options)
      bundle.each do |spec|
        next if options[:no_bundle].include?(spec.name)
        # HAX -- Generate the bin
        bin_dir = @bindir
        path    = @path
        gems_path = @gems_path
        installer = Gem::Installer.allocate
        installer.instance_eval do
          @spec     = spec
          @bin_dir  = bin_dir
          @gem_dir  = gems_path.join(spec.full_name)
          @gem_home = path
          @wrappers = true
          @format_executable = false
          @env_shebang = false
        end
        installer.generate_bin
      end
    end

    def expand_gemfile(spec, options)
      Bundler.logger.info "Installing #{spec.name} (#{spec.version})"

      gemfile = @cache_path.join("#{spec.full_name}.gem").to_s

      if build_args = options[:build_options] && options[:build_options][spec.name]
        Gem::Command.build_args = build_args.map {|k,v| "--with-#{k}=#{v}"}
      end

      installer = Gem::Installer.new(gemfile, options.merge(
        :install_dir         => @path,
        :ignore_dependencies => true,
        :env_shebang         => true,
        :wrappers            => true,
        :bin_dir             => @bindir
      ))
      installer.install
    rescue Gem::InstallError
      cleanup_spec(spec)
      raise
    ensure
      Gem::Command.build_args = []
    end

    def expand_vendored_gem(spec, options)
      add_spec(spec)
      FileUtils.mkdir_p(@gems_path)
      File.symlink(spec.location, @gems_path.join(spec.full_name))
    end

    def add_spec(spec)
      destination = @specs_path
      destination.mkdir unless destination.exist?

      File.open(destination.join("#{spec.full_name}.gemspec"), 'w') do |f|
        f.puts spec.to_ruby
      end
    end

    def cleanup(valid, options)
      to_delete = gems
      to_delete.delete_if do |spec|
        valid.any? { |other| spec.name == other.name && spec.version == other.version }
      end

      valid_executables = valid.map { |s| s.executables }.flatten.compact

      to_delete.each do |spec|
        Bundler.logger.info "Deleting gem: #{spec.name} (#{spec.version})"
        cleanup_spec(spec)
        # Cleanup the bin directory
        spec.executables.each do |bin|
          next if valid_executables.include?(bin)
          Bundler.logger.info "Deleting bin file: #{bin}"
          FileUtils.rm_rf(@bindir.join(bin))
        end
      end
    end

    def cleanup_spec(spec)
      FileUtils.rm_rf(@specs_path.join("#{spec.full_name}.gemspec"))
      FileUtils.rm_rf(@gems_path.join(spec.full_name))
    end

    def expand(options)
      each_repo do |repo|
        repo.expand(options)
      end
    end

    def configure(specs, options)
      FileUtils.mkdir_p(path)
      generate_environment(specs, options)
      generate_environment_picker
    end

    def generate_environment_picker
      FileUtils.cp("#{File.dirname(__FILE__)}/templates/environment_picker.erb", path.join("../../environment.rb"))
    end

    def generate_environment(specs, options)
      load_paths = load_paths_for_specs(specs, options)
      bindir     = @bindir.relative_path_from(path).to_s
      filename   = options[:manifest].relative_path_from(path).to_s

      File.open(path.join("environment.rb"), "w") do |file|
        template = File.read(File.join(File.dirname(__FILE__), "templates", "environment.erb"))
        erb = ERB.new(template, nil, '-')
        file.puts erb.result(binding)
      end
    end

    def load_paths_for_specs(specs, options)
      load_paths = []
      specs.each do |spec|
        next if options[:no_bundle].include?(spec.name)
        gem_path = Pathname.new(spec.full_gem_path)
        if spec.bindir && gem_path.join(spec.bindir).exist?
          load_paths << load_path_for(gem_path, spec.bindir)
        end
        spec.require_paths.each do |path|
          load_paths << load_path_for(gem_path, path)
        end
      end
      load_paths
    end

    def load_path_for(gem_path, path)
      gem_path.join(path).relative_path_from(@path).to_s
    end

    def spec_file_for(spec)
      spec.loaded_from.relative_path_from(@path).to_s
    end

    def require_code(file, dep)
      constraint = case
      when dep.only   then %{ if #{dep.only.inspect}.include?(env)}
      when dep.except then %{ unless #{dep.except.inspect}.include?(env)}
      end
      "require #{file.inspect}#{constraint}"
    end
  end
end
