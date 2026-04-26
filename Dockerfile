FROM ruby:4.0-alpine

WORKDIR /app

RUN apk add --no-cache build-base && mkdir -p /app/log

COPY Gemfile Gemfile.lock* ./
RUN bundle install --jobs 4 --retry 3 && bundle lock

COPY proxy.rb provider_selector.rb config.ru puma.rb ./

EXPOSE 4567

CMD ["bundle", "exec", "puma", "-C", "puma.rb"]
