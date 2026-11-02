#!/bin/sh
# Prints the Homebrew formula for a Nawa release, for the tap
# github.com/bunasys/homebrew-tap (Formula/nawa.rb).
# The release workflow runs it after publishing; run it by hand to
# rebuild the formula for an existing release:
#
#   scripts/homebrew-formula.sh 0.5.0 <macos-arm64 sha256> \
#     <linux-amd64 glibc sha256> <linux-amd64 static sha256>
set -eu

if [ $# -ne 4 ]; then
  echo "usage: $0 <version> <macos-arm64 sha256> <linux-amd64-glibc sha256> <linux-amd64 sha256>" >&2
  exit 64
fi
version=$1
macos_sha=$2
glibc_sha=$3
static_sha=$4
release="https://github.com/bunasys/nawa/releases/download/v$version"

# On Linux the glibc build is installed when the glibc is new enough (the
# system's, or the one Homebrew installs); below that the fully static build
# is used instead, so the formula works on any distribution.
cat <<EOF
class Nawa < Formula
  desc "Small agent harness: agent loop, AI gateway, MCP tools and ACP server"
  homepage "https://github.com/bunasys/nawa"
  license "MIT"

  GLIBC_FLOOR = "2.35"

  on_macos do
    depends_on arch: :arm64
    depends_on macos: :sequoia

    on_arm do
      url "$release/nawa-$version-macos-arm64.tar.gz"
      sha256 "$macos_sha"
    end
  end

  on_linux do
    depends_on arch: :x86_64

    on_intel do
      url "$release/nawa-$version-linux-amd64-glibc.tar.gz"
      sha256 "$glibc_sha"

      resource "static" do
        url "$release/nawa-$version-linux-amd64.tar.gz"
        sha256 "$static_sha"
      end
    end
  end

  def install
    if OS.mac? || OS::Linux::Glibc.version >= Version.new(GLIBC_FLOOR)
      bin.install "nawa"
    else
      resource("static").stage { bin.install "nawa" }
    end
  end

  test do
    assert_match "nawa #{version}", shell_output("#{bin}/nawa --version")
  end
end
EOF
