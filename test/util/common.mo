import Principal "mo:base/Principal";

import TokenHandler "../../src";
import ICRC1 "../../src/ICRC1";
import MockLedger "mock_ledger";
import Mock "mock";
import TestJournal "test_journal";

module {
  func state(handler : TokenHandler.TokenHandler) : (Nat, Nat, Nat) {
    let s = handler.state();
    (
      s.balance.deposited,
      s.balance.consolidated,
      s.users.queued,
    );
  };

  public func createHandler(mock_ledger : MockLedger.MockLedger, triggerOnNotifications : Bool) : (
    TokenHandler.TokenHandler,
    TestJournal.TestJournal,
    () -> (Nat, Nat, Nat),
  ) {

    let ledger = {
      fee = mock_ledger.icrc1_fee;
      balance_of = mock_ledger.icrc1_balance_of;
      transfer = mock_ledger.icrc1_transfer;
      transfer_from = mock_ledger.icrc2_transfer_from;
    };

    let journal = TestJournal.TestJournal();

    let handler = TokenHandler.TokenHandler({
      ledgerApi = ledger;
      ownPrincipal = Principal.fromBlob("");
      initialFee = 0;
      triggerOnNotifications;
      log = journal.log;
    });

    (handler, journal, func() { state(handler) });
  };

  public func createHandlerV2(triggerOnNotifications : Bool) : (
    TokenHandler.TokenHandler,
    TestJournal.TestJournal,
    () -> (Nat, Nat, Nat),
  ) {
    let ledger = object {
      public let fee_ = Mock.Method<Nat>();
      public let balance_ = Mock.Method<Nat>();
      public let transfer_ = Mock.Method<ICRC1.TransferResult>();
      public let transfer_from_ = Mock.Method<ICRC1.TransferFromResult>();
      public shared func fee() : async Nat {
        let r = fee_.pop();
        await* r.run();
        r.response();
      };
      public shared func balance_of(_ : ICRC1.Account) : async Nat {
        let r = balance_.pop();
        await* r.run();
        r.response();
      };
      public shared func transfer(_ : ICRC1.TransferArgs) : async ICRC1.TransferResult {
        let r = transfer_.pop();
        await* r.run();
        r.response();
      };
      public shared func transfer_from(_ : ICRC1.TransferFromArgs) : async ICRC1.TransferFromResult {
        let r = transfer_from_.pop();
        await* r.run();
        r.response();
      };
      public func isEmpty() : Bool {
        fee_.isEmpty() and balance_.isEmpty() and transfer_.isEmpty();
      };
    };

    let journal = TestJournal.TestJournal();

    let handler = TokenHandler.TokenHandler({
      ledgerApi = ledger;
      ownPrincipal = Principal.fromBlob("");
      initialFee = 0;
      triggerOnNotifications;
      log = journal.log;
    });

    (handler, journal, func() { state(handler) });
  };
};
