# Homebrew formula TEMPLATE. The checksums below are placeholders on purpose: the binaries are
# built by the release pipeline, so only it knows their hashes. The release job fills these in
# from the SHA256SUMS of the artifacts it just built and attaches the finished formula to the
# release. Take the formula from the release, not this file.
#
# To publish, put the released formula in a tap repo named `homebrew-tap`:
#
#   brew tap jaenster/tap
#   brew install blizzard-legacy-dl
class BlizzardLegacyDl < Formula
  desc "Download the legacy Blizzard games without running their downloader"
  homepage "https://github.com/jaenster/blizzard-legacy-dl"
  version "__VERSION__"
  license "MIT"

  base = "https://github.com/jaenster/blizzard-legacy-dl/releases/download/v#{version}"

  on_macos do
    on_arm do
      url "#{base}/blizzard-legacy-dl-aarch64-macos"
      sha256 "__SHA256_AARCH64_MACOS__"
    end
    on_intel do
      url "#{base}/blizzard-legacy-dl-x86_64-macos"
      sha256 "__SHA256_X86_64_MACOS__"
    end
  end

  on_linux do
    on_arm do
      url "#{base}/blizzard-legacy-dl-aarch64-linux-musl"
      sha256 "__SHA256_AARCH64_LINUX__"
    end
    on_intel do
      url "#{base}/blizzard-legacy-dl-x86_64-linux-musl"
      sha256 "__SHA256_X86_64_LINUX__"
    end
  end

  def install
    bin.install Dir["blizzard-legacy-dl-*"].first => "blizzard-legacy-dl"
  end

  test do
    assert_match "blizzard-legacy-dl", shell_output("#{bin}/blizzard-legacy-dl 2>&1", 1)
  end
end
