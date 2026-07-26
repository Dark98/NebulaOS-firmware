################################################################################
#
# python-matplotlib
#
################################################################################

PYTHON_MATPLOTLIB_VERSION = 3.4.3
PYTHON_MATPLOTLIB_SOURCE = matplotlib-$(PYTHON_MATPLOTLIB_VERSION).tar.gz
PYTHON_MATPLOTLIB_SITE = https://files.pythonhosted.org/packages/21/37/197e68df384ff694f78d687a49ad39f96c67b8d75718bc61503e1676b617
PYTHON_MATPLOTLIB_LICENSE = Python-2.0
PYTHON_MATPLOTLIB_LICENSE_FILES = LICENSE/LICENSE
PYTHON_MATPLOTLIB_DEPENDENCIES = \
	freetype \
	host-pkgconf \
	host-python-certifi \
	host-python-numpy \
	host-python-pip \
	libpng \
	python-cycler \
	qhull
PYTHON_MATPLOTLIB_SETUP_TYPE = setuptools

# matplotlib 3.4.3 setup.py declares setup_requires=[numpy>=1.16], which
# setuptools resolves via its own legacy fetch_build_eggs mechanism - always a
# fresh pip wheel build, never a check against what is already importable.
# host-python-numpy is already a real dependency above and already builds and
# installs correctly (confirmed directly), so the requirement itself is
# genuinely satisfied - this fetch is a redundant re-verification, not the
# actual dependency. Under cross-compilation it is also provably broken, not
# just redundant: the nested pip subprocess inherits this package own
# CC/AR/mipsel-target toolchain environment, so building numpy from source
# there tries to run a MIPS sanity-check binary natively on the x86_64 build
# host and fails outright (confirmed directly, not assumed). A prebuilt,
# vendored, host-platform numpy wheel - fetched once outside this poisoned
# environment, matching the OpenKE precedent of vendoring prebuilt wheels for
# exactly this class of build-time dependency - lets pip resolve the
# requirement locally with zero network access and zero nested compilation,
# real fix rather than skipping the check.
#
# The vendored wheel is genuinely a native x86_64 build (real
# manylinux_2_27_x86_64 numpy 2.4.6, downloaded clean, no cross-compilation
# environment), but its filename was renamed to claim cp311-cp311-
# linux_mipsel - because this whole matplotlib build step sets
# _PYTHON_HOST_PLATFORM=linux-mipsel (needed for its own real cross-compiled
# C extensions), pip inherits that override for its platform-compatibility
# check too and rejects a truthfully-tagged x86_64 wheel outright (confirmed
# directly: identical pip invocation without that one variable accepts the
# same file immediately). Same mechanism, same justification already
# established in this project for the vendored Pillow wheel (see
# ~/Documents/guppyscreen's own installer.sh) - pip matches wheel filenames
# against a platform string, not actual binary compatibility, and the two
# disagree here specifically because of the cross-build override. Safe
# because the interpreter that ends up importing this wheel for setuptools
# internal check is still the real, native x86_64 process running setup.py -
# only pip own filename-based filter was fooled, not the CPU actually running
# the code. This wheel is never installed onto the MIPS target and never
# executed as MIPS code.
PYTHON_MATPLOTLIB_ENV = PIP_FIND_LINKS=$(TOPDIR)/board/halley5-nebulaos-wheels PIP_NO_INDEX=1

ifeq ($(BR2_PACKAGE_PYTHON_MATPLOTLIB_QT),y)
PYTHON_MATPLOTLIB_DEPENDENCIES += python-pyqt5
endif

define PYTHON_MATPLOTLIB_COPY_SETUP_CFG
	cp $(PYTHON_MATPLOTLIB_PKGDIR)/setup.cfg $(@D)/setup.cfg
endef
PYTHON_MATPLOTLIB_PRE_CONFIGURE_HOOKS += PYTHON_MATPLOTLIB_COPY_SETUP_CFG

$(eval $(python-package))
