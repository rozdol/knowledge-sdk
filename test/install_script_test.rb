# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require_relative "test_helper"

class InstallScriptTest < Minitest::Test
  SCRIPT = File.expand_path("../install.sh", __dir__)

  def test_help_and_shell_syntax
    _stdout, stderr, status = Open3.capture3("sh", "-n", SCRIPT)
    assert status.success?, stderr

    stdout, stderr, status = Open3.capture3("sh", SCRIPT, "--help")
    assert status.success?, stderr
    assert_includes stdout, "Install knowledge-sdk"
    assert_includes stdout, "--ref REF"
  end

  def test_installs_from_git_into_user_gem_directory
    Dir.mktmpdir("knowledge-sdk-installer-") do |root|
      repository = File.join(root, "repository")
      fake_bin = File.join(root, "bin")
      fake_home = File.join(root, "home")
      FileUtils.mkdir_p([repository, fake_bin, fake_home])

      File.write(File.join(repository, "VERSION"), "15.0.0\n")
      File.write(File.join(repository, "knowledge-sdk.gemspec"), "# synthetic fixture\n")
      initialize_repository(repository)
      write_fake_gem(File.join(fake_bin, "gem"))

      ruby_api = "print File.join(Gem.user_dir, 'bin')"
      user_bin, ruby_error, ruby_status = Open3.capture3(
        { "HOME" => fake_home }, "ruby", "-rrubygems", "-e", ruby_api
      )
      assert ruby_status.success?, ruby_error

      environment = {
        "FAKE_KG_BIN" => user_bin,
        "HOME" => fake_home,
        "KNOWLEDGE_SDK_REPOSITORY_URL" => repository,
        "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}"
      }
      stdout, stderr, status = Open3.capture3(
        environment, "sh", SCRIPT, "--user", "--ref", "main"
      )

      assert status.success?, "#{stdout}\n#{stderr}"
      assert_includes stdout, "knowledge-sdk 15.0.0 installed successfully"
      assert File.executable?(File.join(user_bin, "kg"))
    end
  end

  private

  def initialize_repository(repository)
    run_git(repository, "init", "-q")
    run_git(repository, "add", "VERSION", "knowledge-sdk.gemspec")
    run_git(
      repository, "-c", "user.name=Installer Test", "-c",
      "user.email=installer@example.invalid", "commit", "-qm", "fixture"
    )
    run_git(repository, "branch", "-M", "main")
  end

  def run_git(repository, *arguments)
    _stdout, stderr, status = Open3.capture3("git", "-C", repository, *arguments)
    assert status.success?, stderr
  end

  def write_fake_gem(path)
    File.write(path, <<~'SH')
      #!/bin/sh
      set -eu

      case "$1" in
        build)
          version=$(tr -d '[:space:]' < VERSION)
          : > "knowledge-sdk-$version.gem"
          ;;
        install)
          mkdir -p "$FAKE_KG_BIN"
          printf '#!/bin/sh\nprintf "knowledge-sdk 15.0.0\\n"\n' > "$FAKE_KG_BIN/kg"
          chmod +x "$FAKE_KG_BIN/kg"
          ;;
        *)
          exit 99
          ;;
      esac
    SH
    FileUtils.chmod(0o755, path)
  end
end
