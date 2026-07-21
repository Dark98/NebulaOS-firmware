/* Throwaway diagnostic init, not part of the real boot - built statically
 * (no dynamic linker, no busybox) to isolate whether ELF exec itself works
 * at this exact boot moment, independent of busybox/dynamic linking/squashfs
 * fragment reads. Writes directly to /dev/console via raw syscalls, no libc
 * stdio (PID 1 has no open fds yet). If this prints and loops, exec itself
 * is fine and busybox specifically is implicated. If this ALSO panics the
 * same way, the problem is structural to this boot moment, not to busybox.
 *
 * Built with Buildroot's own internal toolchain (not a different one), to
 * keep this a single-variable test against the exact same ABI/libc busybox
 * itself was built with:
 *   docker run --rm --user root \
 *     -v vendor/buildroot-x2000:/src -v scripts/build:/out \
 *     pellcorp/k1-bash-build bash -c \
 *     'PATH=/src/output/host/bin:$PATH mipsel-buildroot-linux-gnu-gcc \
 *      -static -Os -o /out/overlay/diag_init /out/diag_init.c'
 */
#include <fcntl.h>
#include <unistd.h>

int main(void)
{
	int fd = open("/dev/console", O_WRONLY);
	int i = 0;
	char buf[64];

	for (;;) {
		int len = 0;
		const char *msg = "DIAG: static init exec succeeded, iter=";
		while (msg[len]) { buf[len] = msg[len]; len++; }
		buf[len++] = '0' + (i / 100) % 10;
		buf[len++] = '0' + (i / 10) % 10;
		buf[len++] = '0' + i % 10;
		buf[len++] = '\n';
		if (fd >= 0)
			write(fd, buf, len);
		i++;
		sleep(2);
	}
	return 0;
}
