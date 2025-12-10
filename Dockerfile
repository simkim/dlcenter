FROM ruby:3.3.6-slim

RUN apt-get update && apt-get install -y \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set --local without 'test development' \
    && bundle install

COPY . .

EXPOSE 80
CMD ["bundle", "exec", "rackup", "-o", "0.0.0.0", "-p", "80"]
