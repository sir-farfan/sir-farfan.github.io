set -ex

bundle exec jekyll build
bundle exec jekyll serve --incremental

