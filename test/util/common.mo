import Principal "mo:base/Principal";
import TokenHandler "../../src";
import TestJournal "test_journal";

module {
  public func createHandler(ledger : TokenHandler.LedgerAPI, triggerOnNotifications : Bool) : (
    TokenHandler.TokenHandler,
    TestJournal.TestJournal,
    () -> (Nat, Nat, Nat),
  ) {
    let journal = TestJournal.TestJournal();

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
