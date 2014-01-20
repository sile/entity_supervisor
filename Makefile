ERLC_OPTS="[warnings_as_errors, warn_export_all, warn_untyped_record]"
DIALYZER_OPTS=-Werror_handling -Wrace_conditions -Wunmatched_returns

all: init compile xref eunit dialyze

init:
	@ERL_COMPILER_OPTIONS=$(ERLC_OPTS) ./rebar get-deps compile 

compile:
	@ERL_COMPILER_OPTIONS=$(ERLC_OPTS) ./rebar compile skip_deps=true

xref:
	@./rebar xref skip_deps=true

clean:
	@./rebar clean skip_deps=true

eunit:
	@ERL_FLAGS="+W i" ./rebar eunit skip_deps=true

edoc:
	./rebar doc skip_deps=true

start: compile
	@erl -pz ebin

.dialyzer.plt:
	touch .dialyzer.plt
	dialyzer --build_plt --plt .dialyzer.plt --apps erts kernel stdlib -r ebin

dialyze: .dialyzer.plt
	dialyzer --plt .dialyzer.plt -r ebin $(DIALYZER_OPTS)
