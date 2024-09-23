import Principal "mo:base/Principal";
import TokenHandler "../../src";
import ICRC1 "../../src/icrc1-api";
import MockLedger "mock_ledger";
import Mock "mock";
import TestJournal "test_journal";

module {

  public func createHandler(ledger : TokenHandler.LedgerAPI, triggerOnNotifications : Bool, verbose : Bool) : (
    TokenHandler.TokenHandler,
    TestJournal.TestJournal,
    () -> (Nat, Nat, Nat),
  ) {
    let journal = TestJournal.TestJournal(verbose);

    let handler = TokenHandler.TokenHandler({
      ledgerApi = ledger;
      ownPrincipal = Principal.fromBlob("");
      initialFee = 0;
      triggerOnNotifications;
      log = journal.log;
    });

    func state() : (Nat, Nat, Nat) {
      let s = handler.state();
      (s.balance.deposited, s.balance.consolidated, s.users.queued);
    };
    (handler, journal, state);
  };
};
