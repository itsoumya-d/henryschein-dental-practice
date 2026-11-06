FROM ruby:3.3-slim

RUN apt-get update && apt-get install -y --no-install-recommends build-essential && rm -rf /var/lib/apt/lists/*
WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set without "test" && bundle install

COPY . .
EXPOSE 8096
CMD ["bundle", "exec", "puma", "-b", "tcp://0.0.0.0:8096", "config.ru"]
