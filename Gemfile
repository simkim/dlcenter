# DL.Center - File sharing application
source "https://rubygems.org"

ruby '>= 3.3.0'

# Sinatra 3.x is the last version compatible with Rack 2.x (required by thin/sinatra-websocket)
gem 'sinatra', '~> 3.2'
gem 'sinatra-contrib', '~> 3.2'
gem 'sinatra-websocket', '~> 0.3.1'
gem 'uuid', '~> 2.3'
gem 'rubyzip', '~> 2.4'
gem 'zip_tricks', '~> 5.6'
gem 'thin', '~> 1.8'
gem 'rackup', '~> 1.0'

group :development do
  gem 'ruby-prof', '~> 1.7'
end

group :test do
  gem 'rspec', '~> 3.13'
  gem 'rack-test', '~> 2.2'
  gem 'simplecov', '~> 0.22', require: false
  gem 'rubocop', '~> 1.69'
  gem 'ffaker', '~> 2.23'
  gem 'mocha', '~> 2.7'
end
