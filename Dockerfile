FROM ruby:2.3.0
RUN mkdir /app
WORKDIR /app
ADD Gemfile .
RUN bundle install
ADD . .
EXPOSE 80
CMD ["rackup", "-o", "0.0.0.0", "-p", "80"]
