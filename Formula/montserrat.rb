class Montserrat < Formula
  desc "Native read/write ext4 and Linux filesystem tool for modern macOS"
  homepage "https://github.com/cwmoriarty/montserrat"
  url "https://github.com/cwmoriarty/montserrat/archive/refs/tags/v1.0.2.tar.gz"
  sha256 "624f08a406a421374be50d4f7af9579b209ee0f2f917b0624ecc32c59cb25318"
  license "MIT"
  head "https://github.com/cwmoriarty/montserrat.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on macos: :ventura

  def install
    system "./scripts/build.sh"
    bin.install "dist/bin/montserrat"
    bin.install "dist/bin/montserratd" if File.exist?("dist/bin/montserratd")
    (prefix/"engines").install Dir["dist/engines/*"]
    (prefix/"conf").install Dir["dist/conf/*"]
    (prefix/"FSKit").install Dir["dist/FSKit/*"]
  end

  def caveats
    <<~EOS
      Montserrat requires FUSE-T (or macOS 15.4+ FSKit) for mounting user-space filesystems.
      If not already installed, run:
        brew install --cask macos-fuse-t/cask/fuse-t

      To register and start the background auto-mount daemon:
        sudo montserrat daemon install
    EOS
  end

  test do
    assert_match "montserrat version", shell_output("#{bin}/montserrat --version")
    assert_match "Montserrat Engine", shell_output("#{bin}/montserrat engines")
  end
end
