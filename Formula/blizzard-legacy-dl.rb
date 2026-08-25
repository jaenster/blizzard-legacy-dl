# Homebrew formula. To publish it, put this file in a tap repo named `homebrew-tap`:
#
#   brew tap jaenster/tap
#   brew install blizzard-legacy-dl
#
# The release workflow regenerates this with the checksums of the artifacts it just built and
# attaches it to the release, so the hashes below are only current for the version named.
class BlizzardLegacyDl < Formula
  desc "Download the legacy Blizzard games without running their downloader"
  homepage "https://github.com/jaenster/blizzard-legacy-dl"
  version "0.1.0"
  license "MIT"

  base = "https://github.com/jaenster/blizzard-legacy-dl/releases/download/v#{version}"

  on_macos do
    on_arm do
      url "#{base}/blizzard-legacy-dl-aarch64-macos"
      sha256 "2db4efb75c4c54ba76b543489dd906dac6645b283b3db1d149d8a8bb1cebe4c8"
    end
    on_intel do
      url "#{base}/blizzard-legacy-dl-x86_64-macos"
      sha256 "d51d98c245bb80ee18bf27e6fc5a6d61fd07029fbe7867e8108eeef8135bf671"
    end
  end

  on_linux do
    on_arm do
      url "#{base}/blizzard-legacy-dl-aarch64-linux-musl"
      sha256 "e2bcc6c2827cbe8c2bee39e079c1a0b0cf038684ae4629f64be31d5a7583fcf8"
    end
    on_intel do
      url "#{base}/blizzard-legacy-dl-x86_64-linux-musl"
      sha256 "c2add52da7ad0da2767ccab656067f8c7e48165543e091d62139ef5309dcb7f3"
    end
  end

  def install
    bin.install Dir["blizzard-legacy-dl-*"].first => "blizzard-legacy-dl"
  end

  test do
    assert_match "blizzard-legacy-dl", shell_output("#{bin}/blizzard-legacy-dl 2>&1", 1)
  end
end
