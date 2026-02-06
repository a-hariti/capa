#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <version> <asset_url> <sha256>" >&2
  exit 1
fi

version="$1"
asset_url="$2"
sha256="$3"

cat <<FORMULA
class Capa < Formula
  desc "Native macOS screen recorder CLI"
  homepage "https://github.com/a-hariti/capa"
  url "${asset_url}"
  sha256 "${sha256}"
  version "${version}"

  def install
    bin.install "capa"
  end

  test do
    assert_match "Native macOS screen recorder", shell_output("#{bin}/capa --help")
  end
end
FORMULA
