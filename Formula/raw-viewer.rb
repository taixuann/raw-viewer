class RawViewer < Formula
  desc "High-performance scientific raw measurement viewer and CLI"
  homepage "https://github.com/taixuann/raw-viewer"
  version "0.2.0"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/taixuann/raw-viewer/releases/download/v#{version}/raw-viewer-aarch64-apple-darwin.tar.gz"
    else
      url "https://github.com/taixuann/raw-viewer/releases/download/v#{version}/raw-viewer-x86_64-apple-darwin.tar.gz"
    end
  end

  on_linux do
    if Hardware::CPU.intel?
      url "https://github.com/taixuann/raw-viewer/releases/download/v#{version}/raw-viewer-x86_64-unknown-linux-gnu.tar.gz"
    end
  end

  def install
    bin.install "raw-viewer"
  end

  test do
    assert_match "raw-viewer", shell_output("#{bin}/raw-viewer --version")
  end
end
