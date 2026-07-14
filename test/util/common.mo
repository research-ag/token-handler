import Principal "mo:core/Principal";

import TokenHandler "../../src";
import TokenHandlerContext "../../src/TokenHandlerContext";
import TestJournal "test_journal";

module {
  public func createHandler(ledger : TokenHandler.LedgerAPI, triggerOnNotifications : Bool) : (
    TokenHandler.TokenHandler,
    TokenHandlerContext.TokenHandlerContext,
    TestJournal.TestJournal,
    () -> (Nat, Nat, Nat),
  ) {
    let journal = TestJournal.TestJournal();

    let handler = TokenHandler.new({
      ownPrincipal = Principal.fromBlob("");
      initialFee = 0;
      triggerOnNotifications;
      log = journal.log;
    });

    let ctx = TokenHandlerContext.new({
      ledgerApi = ledger;
    });

    func state() : (Nat, Nat, Nat) {
      let s = handler.state();
      (s.balance.deposited, s.balance.consolidated, s.users.queued);
    };
    (handler, ctx, journal, state);
  };
};
