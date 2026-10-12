# -*- encoding: utf-8 -*-
# stub: telegram-bot-ruby 2.8.1 ruby lib

Gem::Specification.new do |s|
  s.name = "telegram-bot-ruby".freeze
  s.version = "2.8.1".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.metadata = { "rubygems_mfa_required" => "true" } if s.respond_to? :metadata=
  s.require_paths = ["lib".freeze]
  s.authors = ["Alexander Tipugin".freeze]
  s.bindir = "exe".freeze
  s.date = "1980-01-02"
  s.email = ["atipugin@gmail.com".freeze]
  s.homepage = "https://github.com/atipugin/telegram-bot".freeze
  s.required_ruby_version = Gem::Requirement.new(">= 2.7".freeze)
  s.rubygems_version = "4.0.16".freeze
  s.summary = "Ruby wrapper for Telegram's Bot API".freeze

  s.installed_by_version = "3.6.9".freeze

  s.specification_version = 4

  s.add_runtime_dependency(%q<dry-struct>.freeze, ["~> 1.6".freeze])
  s.add_runtime_dependency(%q<faraday>.freeze, ["~> 2.0".freeze])
  s.add_runtime_dependency(%q<faraday-multipart>.freeze, ["~> 1.0".freeze])
  s.add_runtime_dependency(%q<zeitwerk>.freeze, ["~> 2.6".freeze])
end
