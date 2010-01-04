require 'pathname'
require 'logger'
require 'set'
require 'erb'
# Required elements of rubygems
require "rubygems/remote_fetcher"
require "rubygems/installer"

require "bundler/gem_bundle"
require "bundler/source"
require "bundler/finder"
require "bundler/gem_ext"
require "bundler/resolver"
require "bundler/environment"
require "bundler/dsl"
require "bundler/cli"
require "bundler/bundle"
require "bundler/dependency"
require "bundler/remote_specification"

# Symbol#to_proc fix for Ruby 1.8.6 and below
require "facets/symbol/to_proc" unless :symbol.respond_to? :to_proc

module Bundler
  VERSION = "0.7.2"

  class << self
    attr_writer :logger

    def logger
      @logger ||= begin
        logger = Logger.new(STDOUT, Logger::INFO)
        logger.formatter = proc {|_,_,_,msg| "#{msg}\n" }
        logger
      end
    end
  end
end
