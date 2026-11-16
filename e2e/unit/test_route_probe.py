"""route_probe must never report a vacuous zero.

`rest_upsert == 0` is test_77's PASSING value (and `crdt_create == 0` is
test_107's), and a raising telemetry handler is detached silently and then
reads 0 forever. The parser is the guard.
"""

import pytest

from helpers.route_probe import Routes, parse_routes


def test_parses_counts_when_both_handlers_attached():
    assert parse_routes("1000,0,2,3,4,true,true\n") == Routes(1000, 0, 2, 3, 4)


@pytest.mark.parametrize("line", ["1000,0,0,0,0,false,true", "1000,0,0,0,0,true,false"])
def test_detached_handler_refuses_to_report(line):
    with pytest.raises(AssertionError, match="detached"):
        parse_routes(line)


@pytest.mark.parametrize("line", ["armed", "1000,0,true,true"])
def test_malformed_line_fails_loudly(line):
    with pytest.raises(AssertionError, match="route probe returned"):
        parse_routes(line)
