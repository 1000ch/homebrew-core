class MysqlAT56 < Formula
  desc "Open source relational database management system"
  homepage "https://dev.mysql.com/doc/refman/5.6/en/"
  url "https://dev.mysql.com/get/Downloads/MySQL-5.6/mysql-5.6.41.tar.gz"
  sha256 "4a223c3daed88f8450fa2fc8fd0e7afe2b1a122dd58b74c4ea6526d6a72563ce"

  bottle do
    sha256 "d40cfd2b1c4a9676e7e054ac02aa3c100e098c681837793c6a9a80f60cda9f78" => :mojave
    sha256 "f38c2f721f15779682345a364ed5adf2550163986a1dd50e7bfc945ddc3b68cf" => :high_sierra
    sha256 "a85b38c407bd23ed63683c5e66c0cc2bb3e4727c737c94a43956b3fd442f91a4" => :sierra
    sha256 "7f668566960c8671fdc237eb3af7cdce546a51445b5933288e4b6ed196296396" => :el_capitan
  end

  keg_only :versioned_formula

  option "with-embedded", "Build the embedded server"
  option "with-archive-storage-engine", "Compile with the ARCHIVE storage engine enabled"
  option "with-blackhole-storage-engine", "Compile with the BLACKHOLE storage engine enabled"
  option "with-local-infile", "Build with local infile loading support"
  option "with-memcached", "Enable innodb-memcached support"

  deprecated_option "enable-local-infile" => "with-local-infile"
  deprecated_option "enable-memcached" => "with-memcached"

  depends_on "cmake" => :build
  depends_on "pidof" unless MacOS.version >= :mountain_lion
  depends_on "openssl"

  def datadir
    var/"mysql"
  end

  def install
    # Don't hard-code the libtool path. See:
    # https://github.com/Homebrew/homebrew/issues/20185
    inreplace "cmake/libutils.cmake",
      "COMMAND /usr/bin/libtool -static -o ${TARGET_LOCATION}",
      "COMMAND libtool -static -o ${TARGET_LOCATION}"

    # -DINSTALL_* are relative to `CMAKE_INSTALL_PREFIX` (`prefix`)
    args = %W[
      -DMYSQL_DATADIR=#{datadir}
      -DINSTALL_INCLUDEDIR=include/mysql
      -DINSTALL_MANDIR=share/man
      -DINSTALL_DOCDIR=share/doc/#{name}
      -DINSTALL_INFODIR=share/info
      -DINSTALL_MYSQLSHAREDIR=share/mysql
      -DWITH_SSL=system
      -DDEFAULT_CHARSET=utf8
      -DDEFAULT_COLLATION=utf8_general_ci
      -DSYSCONFDIR=#{etc}
      -DCOMPILATION_COMMENT=Homebrew
      -DWITH_EDITLINE=system
      -DWITH_UNIT_TESTS=OFF
    ]

    # Build the embedded server
    args << "-DWITH_EMBEDDED_SERVER=ON" if build.with? "embedded"

    # Compile with ARCHIVE engine enabled if chosen
    args << "-DWITH_ARCHIVE_STORAGE_ENGINE=1" if build.with? "archive-storage-engine"

    # Compile with BLACKHOLE engine enabled if chosen
    args << "-DWITH_BLACKHOLE_STORAGE_ENGINE=1" if build.with? "blackhole-storage-engine"

    # Build with local infile loading support
    args << "-DENABLED_LOCAL_INFILE=1" if build.with? "local-infile"

    # Build with memcached support
    args << "-DWITH_INNODB_MEMCACHED=1" if build.with? "memcached"

    system "cmake", ".", *std_cmake_args, *args
    system "make"
    system "make", "install"

    # We don't want to keep a 240MB+ folder around most users won't need.
    (prefix/"mysql-test").cd do
      system "./mysql-test-run.pl", "status", "--vardir=#{Dir.mktmpdir}"
    end
    rm_rf prefix/"mysql-test"

    # Don't create databases inside of the prefix!
    # See: https://github.com/Homebrew/homebrew/issues/4975
    rm_rf prefix/"data"

    # Link the setup script into bin
    bin.install_symlink prefix/"scripts/mysql_install_db"

    # Fix up the control script and link into bin
    inreplace "#{prefix}/support-files/mysql.server",
              /^(PATH=".*)(")/, "\\1:#{HOMEBREW_PREFIX}/bin\\2"

    bin.install_symlink prefix/"support-files/mysql.server"

    libexec.install bin/"mysqlaccess"
    libexec.install bin/"mysqlaccess.conf"

    # Install my.cnf that binds to 127.0.0.1 by default
    (buildpath/"my.cnf").write <<~EOS
      # Default Homebrew MySQL server config
      [mysqld]
      # Only allow connections from localhost
      bind-address = 127.0.0.1
    EOS
    etc.install "my.cnf"
  end

  def post_install
    # Make sure the datadir exists
    datadir.mkpath
    unless (datadir/"mysql/general_log.CSM").exist?
      ENV["TMPDIR"] = nil
      system bin/"mysql_install_db", "--verbose", "--user=#{ENV["USER"]}",
        "--basedir=#{prefix}", "--datadir=#{datadir}", "--tmpdir=/tmp"
    end
  end

  def caveats; <<~EOS
    A "/etc/my.cnf" from another install may interfere with a Homebrew-built
    server starting up correctly.

    MySQL is configured to only allow connections from localhost by default

    To connect:
        mysql -uroot
  EOS
  end

  plist_options :manual => "#{HOMEBREW_PREFIX}/opt/mysql@5.6/bin/mysql.server start"

  def plist; <<~EOS
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>KeepAlive</key>
      <true/>
      <key>Label</key>
      <string>#{plist_name}</string>
      <key>ProgramArguments</key>
      <array>
        <string>#{opt_bin}/mysqld_safe</string>
        <string>--datadir=#{datadir}</string>
      </array>
      <key>RunAtLoad</key>
      <true/>
      <key>WorkingDirectory</key>
      <string>#{datadir}</string>
    </dict>
    </plist>
  EOS
  end

  test do
    begin
      # Expects datadir to be a completely clean dir, which testpath isn't.
      dir = Dir.mktmpdir
      system bin/"mysql_install_db", "--user=#{ENV["USER"]}",
      "--basedir=#{prefix}", "--datadir=#{dir}", "--tmpdir=#{dir}"

      pid = fork do
        exec bin/"mysqld", "--datadir=#{dir}"
      end
      sleep 2

      output = shell_output("curl 127.0.0.1:3306")
      output.force_encoding("ASCII-8BIT") if output.respond_to?(:force_encoding)
      assert_match version.to_s, output
    ensure
      Process.kill(9, pid)
      Process.wait(pid)
    end
  end
end
