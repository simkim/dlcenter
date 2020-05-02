FROM ruby:2.7.0
RUN mkdir /app
WORKDIR /app
ADD Gemfile .
ADD Gemfile.lock .
RUN gem install bundler:1.17.2
RUN bundle install --without test
ADD . .
EXPOSE 80
CMD ["rackup", "-o", "0.0.0.0", "-p", "80"]
