EBIN_DIR = ebin
SRC_DIR = src
ERLC = erlc

all: clean ebin

ebin: $(SRC_DIR)/*.*
	mkdir -p $(EBIN_DIR)
	$(ERLC) -DTEST -o $(EBIN_DIR) -I $(SRC_DIR) $(SRC_DIR)/*.erl

clean:
	rm -fr $(EBIN_DIR)

test: ebin
	./support/run_tests.escript $(EBIN_DIR)