import AsyncMethodTester "mo:await-async";
import ICRC1 "../../src/icrc1-api";

module {
  public class MockLedger() {
    public let fee_ = AsyncMethodTester.AsyncVariableTester<Nat>(0, null);

    public let balance_ = AsyncMethodTester.AsyncVariableTester<Nat>(0, null);

    public let transfer_ = AsyncMethodTester.AsyncVariableTester<ICRC1.TransferResult>(#Ok 42, null);
    var transfer_count_ = 0;

    public let transfer_from_ = AsyncMethodTester.AsyncVariableTester<ICRC1.TransferFromResult>(#Ok 42, null);
    var transfer_from_count_ = 0;

    public func reset_state() : async () {
      fee_.reset();
      balance_.reset();

      transfer_.reset();
      transfer_count_ := 0;

      transfer_from_.reset();
      transfer_from_count_ := 0;
    };

    public shared func fee() : async Nat {
      await* fee_.await_unlock();
      fee_.get();
    };

    public shared func balance_of(_ : ICRC1.Account) : async Nat {
      await* balance_.await_unlock();
      balance_.get();
    };

    public shared func transfer(_ : ICRC1.TransferArgs) : async ICRC1.TransferResult {
      await* transfer_.await_unlock();
      transfer_count_ += 1;
      transfer_.get();
    };

    public func transfer_count() : async Nat = async transfer_count_;

    public shared func transfer_from(_ : ICRC1.TransferFromArgs) : async ICRC1.TransferFromResult {
      await* transfer_from_.await_unlock();
      transfer_from_count_ += 1;
      transfer_from_.get();
    };

    public func transfer_from_count() : async Nat = async transfer_from_count_;
  };
};
