# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require_relative "test_helper"

class UpdateScriptTest < Minitest::Test
  SCRIPT = File.expand_path("../update.sh", __dir__)

  def test_help_and_shell_syntax
    _stdout, stderr, status = Open3.capture3("sh", "-n", SCRIPT)
    assert status.success?, stderr

    stdout, stderr, status = Open3.capture3("sh", SCRIPT, "--help")
    assert status.success?, stderr
    assert_includes stdout, "Update an installed knowledge-sdk"
    assert_includes stdout, "--ref REF"
  end

  def test_updates_installed_version_and_forwards_install_options
    Dir.mktmpdir("knowledge-sdk-updater-") do |root|
      fake_bin = File.join(root, "bin")
      version_file = File.join(root, "version")
      installer = File.join(root, "installer.sh")
      FileUtils.mkdir_p(fake_bin)
      File.write(version_file, "15.0.0")
      write_fake_ruby(File.join(fake_bin, "ruby"))
      write_fake_curl(File.join(fake_bin, "curl"))
      write_fake_installer(installer)

      environment = {
        "FAKE_INSTALLER" => installer,
        "FAKE_VERSION_FILE" => version_file,
        "KNOWLEDGE_SDK_INSTALLER_URL" => "https://example.invalid/install.sh",
        "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}"
      }
      stdout, stderr, status = Open3.capture3(environment, "sh", SCRIPT, "--user")

      assert status.success?, "#{stdout}\n#{stderr}"
      assert_includes stdout, "knowledge-sdk updated: 15.0.0 -> 17.0.0"
      assert_equal "17.0.0", File.read(version_file)
    end
  end

  private

  def write_fake_ruby(path)
    write_executable(path, <<~'SH')
      #!/bin/sh
      set -eu

      if [ "$#" -gt 3 ]; then
        exit 0
      fi
      cat "$FAKE_VERSION_FILE"
    SH
  end

  def write_fake_curl(path)
    write_executable(path, <<~'SH')
      #!/bin/sh
      set -eu

      while [ "$#" -gt 0 ]; do
        if [ "$1" = "-o" ]; then
          cp "$FAKE_INSTALLER" "$2"
          exit 0
        fi
        shift
      done
      exit 1
    SH
  end

  def write_fake_installer(path)
    write_executable(path, <<~'SH')
      #!/bin/sh
      set -eu

      [ "$1" = "--ref" ]
      [ "$2" = "main" ]
      [ "$3" = "--user" ]
      printf '17.0.0' > "$FAKE_VERSION_FILE"
    SH
  end

  def write_executable(path, content)
    File.write(path, content)
    FileUtils.chmod(0o755, path)
  end
end
