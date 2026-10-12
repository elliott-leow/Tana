CC = xcrun clang
CFLAGS = -std=c11 -Wall -Wextra -O2 -g -fno-objc-arc -fvisibility=hidden -mmacosx-version-min=14.0
FRAMEWORKS = -F/System/Library/PrivateFrameworks -framework Carbon -framework Cocoa -framework CoreServices -framework CoreVideo -framework QuartzCore -framework SkyLight
SOURCES = vendor/yabai/src/manifest.m vendor/yabai/src/osax/payload_bin.c vendor/yabai/src/osax/loader_bin.c
HEADERS = $(shell find src vendor/yabai/src -name '*.h' -o -name '*.c' -o -name '*.m')
OSAX_DEPS = $(wildcard vendor/yabai/src/osax/*.m vendor/yabai/src/osax/*.h vendor/yabai/src/misc/*.h)

.PHONY: all test bench clean
all: build/tana
vendor/yabai/src/osax/payload_bin.c: $(OSAX_DEPS)
	$(MAKE) -B -C vendor/yabai ./src/osax/payload_bin.c
# The vendored generation step writes both files. This dependency prevents two
# parallel recipes from compiling and overwriting the same generated payload.
vendor/yabai/src/osax/loader_bin.c: vendor/yabai/src/osax/payload_bin.c
	@test -f $@ || $(MAKE) -B -C vendor/yabai ./src/osax/loader_bin.c
build/tana: $(SOURCES) $(HEADERS)
	mkdir -p build
	$(CC) $(CFLAGS) $(SOURCES) $(FRAMEWORKS) -o $@
test:
	mkdir -p build
	$(CC) -std=c99 -Wall -Wextra -Werror -fsanitize=address,undefined -g tests/strip_geometry_test.c -o build/strip_geometry_test
	./build/strip_geometry_test
	$(CC) -std=c99 -Wall -Wextra -Werror -fsanitize=address,undefined -g tests/sa_transport_test.c -o build/sa_transport_test
	./build/sa_transport_test
	$(CC) -std=c99 -Wall -Wextra -Werror -fsanitize=address,undefined -g tests/strip_columns_test.c -o build/strip_columns_test
	./build/strip_columns_test
	$(CC) -std=c99 -Wall -Wextra -Werror -fsanitize=address,undefined -g tests/overview_geometry_test.c -o build/overview_geometry_test
	./build/overview_geometry_test
	$(CC) -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g tests/strip_runtime_test.m -framework Cocoa -o build/strip_runtime_test
	./build/strip_runtime_test
	python3 -m unittest discover -s tests -p 'test_*.py'
bench:
	mkdir -p build
	$(CC) -std=c11 -Wall -Wextra -Werror -O2 tests/performance_bench.c -o build/performance_bench
	./build/performance_bench
clean:
	rm -f build/tana build/strip_geometry_test
