import TestJournal "test_journal";
import Principal "mo:base/Principal";

do {
  let anon_p = Principal.fromBlob("");
  let journal = TestJournal.TestJournal();

  // initial state
  assert journal.hasEvents([]);
  assert journal.size() == 0;

  // add some logs
  journal.log(anon_p, #newDeposit(1));
  journal.log(anon_p, #issued(1));
  assert journal.hasEvents([#newDeposit(1), #issued(1)]);
  assert journal.size() == 2;

  // check with no new events
  assert journal.hasEvents([]);
  assert journal.hasEvents([#newDeposit(10)]) == false;
  assert journal.hasEvents([]);
  assert journal.size() == 2;
};
