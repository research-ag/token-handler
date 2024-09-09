import AsyncMethodTester "mo:await-async";
import ICRC1 "../../src/ICRC1";

module {
  public class MockLedger() {
    public let fee = AsyncMethodTester.AsyncVariableTester<Nat>(0, null);

    public let balance = AsyncMethodTester.AsyncVariableTester<Nat>(0, null);

    public let transfer = AsyncMethodTester.AsyncVariableTester<ICRC1.TransferResult>(#Ok 42, null);
    var transfer_count_ = 0;

    public let transfer_from = AsyncMethodTester.AsyncVariableTester<ICRC1.TransferFromResult>(#Ok 42, null);
    var transfer_from_count_ = 0;

    public func reset_state() : async () {
      fee.reset();
      balance.reset();

      transfer.reset();
      transfer_count_ := 0;

      transfer_from.reset();
      transfer_from_count_ := 0;
    };

    public shared func icrc1_fee() : async Nat {
      await* fee.await_unlock();
      fee.get();
    };

    public shared func icrc1_balance_of(_ : ICRC1.Account) : async Nat {
      await* balance.await_unlock();
      balance.get();
    };

    public shared func icrc1_transfer(_ : ICRC1.TransferArgs) : async ICRC1.TransferResult {
      await* transfer.await_unlock();
      transfer_count_ += 1;
      transfer.get();
    };

    public func transfer_count() : async Nat = async transfer_count_;

    public shared func icrc2_transfer_from(_ : ICRC1.TransferFromArgs) : async ICRC1.TransferFromResult {
      await* transfer_from.await_unlock();
      transfer_from_count_ += 1;
      transfer_from.get();
    };

    public func transfer_from_count() : async Nat = async transfer_from_count_;
  };
};
