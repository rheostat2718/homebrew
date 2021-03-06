require 'formula'

class Setuptools < Formula
  url 'https://pypi.python.org/packages/source/s/setuptools/setuptools-0.9.7.tar.gz'
  sha1 'c56c5cc55b678c25a0a06f25a122f6492d62e2d3'
end

class Pip < Formula
  url 'https://pypi.python.org/packages/source/p/pip/pip-1.4.tar.gz'
  sha1 '3149dc77c66b77d02497205fca5df56ae9d3e753'
end

class Python < Formula
  homepage 'http://www.python.org'
  url 'http://www.python.org/ftp/python/2.7.5/Python-2.7.5.tar.bz2'
  sha1 '6cfada1a739544a6fa7f2601b500fba02229656b'

  head 'http://hg.python.org/cpython', :using => :hg, :branch => '2.7'

  option :universal
  option 'quicktest', 'Run `make quicktest` after the build (for devs; may fail)'
  option 'with-brewed-openssl', "Use Homebrew's openSSL instead of the one from OS X"
  option 'with-brewed-tk', "Use Homebrew's Tk (has optional Cocoa and threads support)"
  option 'with-poll', 'Enable select.poll, which is not fully implemented on OS X (http://bugs.python.org/issue5154)'
  # --with-dtrace relies on CLT as dtrace hard-codes paths to /usr
  option 'with-dtrace', 'Experimental DTrace support (http://bugs.python.org/issue13405)' if MacOS::CLT.installed?

  depends_on 'pkg-config' => :build
  depends_on 'readline' => :recommended
  depends_on 'sqlite' => :recommended
  depends_on 'gdbm' => :recommended
  depends_on 'openssl' if build.with? 'brewed-openssl'
  depends_on 'homebrew/dupes/tcl-tk' if build.with? 'brewed-tk'

  def patches
    p = []
    p << 'https://gist.github.com/paxswill/5402840/raw/75646d5860685c8be98858288d1772f64d6d5193/pythondtrace-patch.diff' if build.with? 'dtrace'
    # Patch to disable the search for Tk.frameworked, since homebrew's Tk is
    # a plain unix build. Remove `-lX11`, too because our Tk is "AquaTk".
    p << DATA if build.with? 'brewed-tk'
    p
  end

  def site_packages_cellar
    prefix/"Frameworks/Python.framework/Versions/2.7/lib/python2.7/site-packages"
  end

  # The HOMEBREW_PREFIX location of site-packages.
  def site_packages
    HOMEBREW_PREFIX/"lib/python2.7/site-packages"
  end

  def install
    opoo 'The given option --with-poll enables a somewhat broken poll() on OS X (http://bugs.python.org/issue5154).' if build.with? 'poll'

    # Unset these so that installing pip and setuptools puts them where we want
    # and not into some other Python the user has installed.
    ENV['PYTHONHOME'] = nil

    args = %W[
             --prefix=#{prefix}
             --enable-ipv6
             --datarootdir=#{share}
             --datadir=#{share}
             --enable-framework=#{prefix}/Frameworks
           ]

    args << '--without-gcc' if ENV.compiler == :clang
    args << '--with-dtrace' if build.with? 'dtrace'

    if superenv?
      distutils_fix_superenv(args)
    else
      distutils_fix_stdenv
    end

    if build.universal?
      ENV.universal_binary
      args << "--enable-universalsdk=/" << "--with-universal-archs=intel"
    end

    # Allow sqlite3 module to load extensions: http://docs.python.org/library/sqlite3.html#f1
    inreplace("setup.py", 'sqlite_defines.append(("SQLITE_OMIT_LOAD_EXTENSION", "1"))', '') if build.with? 'sqlite'

    # Allow python modules to use ctypes.find_library to find homebrew's stuff
    # even if homebrew is not a /usr/local/lib. Try this with:
    # `brew install enchant && pip install pyenchant`
    inreplace "./Lib/ctypes/macholib/dyld.py" do |f|
      f.gsub! 'DEFAULT_LIBRARY_FALLBACK = [', "DEFAULT_LIBRARY_FALLBACK = [ '#{HOMEBREW_PREFIX}/lib',"
      f.gsub! 'DEFAULT_FRAMEWORK_FALLBACK = [', "DEFAULT_FRAMEWORK_FALLBACK = [ '#{HOMEBREW_PREFIX}/Frameworks',"
    end

    # Fix http://bugs.python.org/issue18071
    inreplace "./Lib/_osx_support.py", "compiler_so = list(compiler_so)",
              "if isinstance(compiler_so, (str,unicode)): compiler_so = compiler_so.split()"

    if build.with? 'brewed-tk'
      ENV.append 'CPPFLAGS', "-I#{Formula.factory('tcl-tk').opt_prefix}/include"
      ENV.append 'LDFLAGS', "-L#{Formula.factory('tcl-tk').opt_prefix}/lib"
    end

    system "./configure", *args

    # HAVE_POLL is "broken" on OS X
    # See: http://trac.macports.org/ticket/18376 and http://bugs.python.org/issue5154
    inreplace 'pyconfig.h', /.*?(HAVE_POLL[_A-Z]*).*/, '#undef \1' unless build.with? "poll"

    system "make"

    ENV.deparallelize # Installs must be serialized
    # Tell Python not to install into /Applications (default for framework builds)
    system "make", "install", "PYTHONAPPSDIR=#{prefix}"
    # Demos and Tools
    (HOMEBREW_PREFIX/'share/python').mkpath
    system "make", "frameworkinstallextras", "PYTHONAPPSDIR=#{share}/python"
    system "make", "quicktest" if build.include? 'quicktest'

    # Post-install, fix up the site-packages so that user-installed Python
    # software survives minor updates, such as going from 2.7.0 to 2.7.1:

    # Remove the site-packages that Python created in its Cellar.
    site_packages_cellar.rmtree
    # Create a site-packages in HOMEBREW_PREFIX/lib/python2.7/site-packages
    site_packages.mkpath
    # Symlink the prefix site-packages into the cellar.
    ln_s site_packages, site_packages_cellar

    # We ship setuptools and pip and reuse the PythonInstalled
    # Requirement here to write the sitecustomize.py
    py = PythonInstalled.new("2.7")

    # Remove old setuptools installations that may still fly around and be
    # listed in the easy_install.pth. This can break setuptools build with
    # zipimport.ZipImportError: bad local file header
    # setuptools-0.9.5-py3.3.egg
    rm_rf Dir["#{py.global_site_packages}/setuptools*"]
    rm_rf Dir["#{py.global_site_packages}/distribute*"]

    py.binary = bin/'python'
    py.modify_build_environment
    setup_args = [ "-s", "setup.py", "--no-user-cfg", "install", "--force", "--verbose",
                   "--install-scripts=#{bin}", "--install-lib=#{site_packages}" ]
    Setuptools.new.brew { system "#{bin}/python2", *setup_args }
    Pip.new.brew { system "#{bin}/python2", *setup_args }

    # And now we write the distuitsl.cfg
    cfg = prefix/"Frameworks/Python.framework/Versions/2.7/lib/python2.7/distutils/distutils.cfg"
    cfg.delete if cfg.exist?
    cfg.write <<-EOF.undent
      [global]
      verbose=1
      [install]
      force=1
      prefix=#{HOMEBREW_PREFIX}
    EOF

    # Work-around for that bug: http://bugs.python.org/issue18050
    inreplace "#{prefix}/Frameworks/Python.framework/Versions/2.7/lib/python2.7/re.py", 'import sys', <<-EOS.undent
      import sys
      try:
          from _sre import MAXREPEAT
      except ImportError:
          import _sre
          _sre.MAXREPEAT = 65535 # this monkey-patches all other places of "from _sre import MAXREPEAT"'
      EOS

      # Fixes setting Python build flags for certain software
      # See: https://github.com/mxcl/homebrew/pull/20182
      # http://bugs.python.org/issue3588
      inreplace "#{prefix}/Frameworks/Python.framework/Versions/2.7/lib/python2.7/config/Makefile" do |s|
        s.change_make_var! "LINKFORSHARED",
          "-u _PyMac_Error $(PYTHONFRAMEWORKINSTALLDIR)/Versions/$(VERSION)/$(PYTHONFRAMEWORK)"
      end
  end

  def distutils_fix_superenv(args)
    # This is not for building python itself but to allow Python's build tools
    # (pip) to find brewed stuff when installing python packages.
    cflags = "CFLAGS=-I#{HOMEBREW_PREFIX}/include -I#{Formula.factory('sqlite').opt_prefix}/include"
    ldflags = "LDFLAGS=-L#{HOMEBREW_PREFIX}/lib -L#{Formula.factory('sqlite').opt_prefix}/lib"
    if build.with? 'brewed-tk'
      cflags += " -I#{Formula.factory('tcl-tk').opt_prefix}/include"
      ldflags += " -L#{Formula.factory('tcl-tk').opt_prefix}/lib"
    end
    unless MacOS::CLT.installed?
      # Help Python's build system (setuptools/pip) to build things on Xcode-only systems
      # The setup.py looks at "-isysroot" to get the sysroot (and not at --sysroot)
      cflags += " -isysroot #{MacOS.sdk_path}"
      ldflags += " -isysroot #{MacOS.sdk_path}"
      # Same zlib.h-not-found-bug as in env :std (see below)
      args << "CPPFLAGS=-I#{MacOS.sdk_path}/usr/include"
      # For the Xlib.h, Python needs this header dir with the system Tk
      if build.without? 'brewed-tk'
        cflags += " -I#{MacOS.sdk_path}/System/Library/Frameworks/Tk.framework/Versions/8.5/Headers"
      end
    end
    args << cflags
    args << ldflags
    # Avoid linking to libgcc http://code.activestate.com/lists/python-dev/112195/
    args << "MACOSX_DEPLOYMENT_TARGET=#{MacOS.version}"
    # We want our readline! This is just to outsmart the detection code,
    # superenv handles that cc finds includes/libs!
    inreplace "setup.py",
              "do_readline = self.compiler.find_library_file(lib_dirs, 'readline')",
              "do_readline = '#{HOMEBREW_PREFIX}/opt/readline/lib/libhistory.dylib'"
  end

  def distutils_fix_stdenv()
    # Python scans all "-I" dirs but not "-isysroot", so we add
    # the needed includes with "-I" here to avoid this err:
    #     building dbm using ndbm
    #     error: /usr/include/zlib.h: No such file or directory
    ENV.append 'CPPFLAGS', "-I#{MacOS.sdk_path}/usr/include" unless MacOS::CLT.installed?

    # Don't use optimizations other than "-Os" here, because Python's distutils
    # remembers (hint: `python3-config --cflags`) and reuses them for C
    # extensions which can break software (such as scipy 0.11 fails when
    # "-msse4" is present.)
    ENV.minimal_optimization

    # We need to enable warnings because the configure.in uses -Werror to detect
    # "whether gcc supports ParseTuple" (https://github.com/mxcl/homebrew/issues/12194)
    ENV.enable_warnings
    if ENV.compiler == :clang
      # http://docs.python.org/devguide/setup.html#id8 suggests to disable some Warnings.
      ENV.append_to_cflags '-Wno-unused-value'
      ENV.append_to_cflags '-Wno-empty-body'
      ENV.append_to_cflags '-Qunused-arguments'
    end
  end

  def caveats
    <<-EOS.undent
      Python demo
        #{HOMEBREW_PREFIX}/share/python/Extras

      Setuptools and Pip have been installed. To update them
        pip install --upgrade setuptools
        pip install --upgrade pip

      To symlink "Idle" and the "Python Launcher" to ~/Applications
        `brew linkapps`

      You can install Python packages with (the outdated easy_install or)
        `pip install <your_favorite_package>`

      They will install into the site-package directory
        #{site_packages}

      See: https://github.com/mxcl/homebrew/wiki/Homebrew-and-Python
    EOS
  end

  test do
    # Check if sqlite is ok, because we build with --enable-loadable-sqlite-extensions
    # and it can occur that building sqlite silently fails if OSX's sqlite is used.
    system "#{bin}/python", "-c", "import sqlite3"
    # Check if some other modules import. Then the linked libs are working.
    system "#{bin}/python", "-c", "import Tkinter; root = Tkinter.Tk()"
  end
end

__END__
diff --git a/setup.py b/setup.py
index 716f08e..66114ef 100644
--- a/setup.py
+++ b/setup.py
@@ -1810,9 +1810,6 @@ class PyBuildExt(build_ext):
         # Rather than complicate the code below, detecting and building
         # AquaTk is a separate method. Only one Tkinter will be built on
         # Darwin - either AquaTk, if it is found, or X11 based Tk.
-        if (host_platform == 'darwin' and
-            self.detect_tkinter_darwin(inc_dirs, lib_dirs)):
-            return
 
         # Assume we haven't found any of the libraries or include files
         # The versions with dots are used on Unix, and the versions without
@@ -1858,21 +1855,6 @@ class PyBuildExt(build_ext):
             if dir not in include_dirs:
                 include_dirs.append(dir)

-        # Check for various platform-specific directories
-        if host_platform == 'sunos5':
-            include_dirs.append('/usr/openwin/include')
-            added_lib_dirs.append('/usr/openwin/lib')
-        elif os.path.exists('/usr/X11R6/include'):
-            include_dirs.append('/usr/X11R6/include')
-            added_lib_dirs.append('/usr/X11R6/lib64')
-            added_lib_dirs.append('/usr/X11R6/lib')
-        elif os.path.exists('/usr/X11R5/include'):
-            include_dirs.append('/usr/X11R5/include')
-            added_lib_dirs.append('/usr/X11R5/lib')
-        else:
-            # Assume default location for X11
-            include_dirs.append('/usr/X11/include')
-            added_lib_dirs.append('/usr/X11/lib')
 
         # If Cygwin, then verify that X is installed before proceeding
         if host_platform == 'cygwin':
@@ -1897,9 +1879,6 @@ class PyBuildExt(build_ext):
         if host_platform in ['aix3', 'aix4']:
             libs.append('ld')
 
-        # Finally, link with the X11 libraries (not appropriate on cygwin)
-        if host_platform != "cygwin":
-            libs.append('X11')
 
         ext = Extension('_tkinter', ['_tkinter.c', 'tkappinit.c'],
                         define_macros=[('WITH_APPINIT', 1)] + defs,
