EBIN_DIR = ebin
SRC_DIR = src
ERLC = erlc

all: clean ebin

ebin:
	@mkdir -p $(EBIN_DIR)
	$(ERLC) -o $(EBIN_DIR) -I $(SRC_DIR) $(SRC_DIR)/*.erl

clean:
	@rm -fr $(EBIN_DIR)
