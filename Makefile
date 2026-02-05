BIN := capa
SPM := swift

.PHONY: build install run clean

build:
	$(SPM) build -c release --disable-sandbox

# Produces a single, gitignored top-level binary: ./capa
install: build
	cp .build/release/$(BIN) ./$(BIN)
	chmod +x ./$(BIN)

# Pass args via: make run ARGS="--non-interactive --duration 5"
run: install
	./$(BIN) $(ARGS)

clean:
	rm -f ./$(BIN)
	$(SPM) package clean
