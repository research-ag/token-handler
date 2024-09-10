import ICRC1 "../../src/icrc1-api";
import AsyncMethodTester "mo:await-async";

module {
  public class MockLedgerV2() {
    public let fee_ = AsyncMethodTester.SimpleStageAsyncMethodTester<Nat>(null);
    public let balance_ = AsyncMethodTester.SimpleStageAsyncMethodTester<Nat>(null);
    public let transfer_ = AsyncMethodTester.SimpleStageAsyncMethodTester<ICRC1.TransferResult>(null);
    public let transfer_from_ = AsyncMethodTester.SimpleStageAsyncMethodTester<ICRC1.TransferFromResult>(null);
    
    public shared func fee() : async Nat {
      fee_.call_result(await* fee_.call());
    };
    
    public shared func balance_of(_ : ICRC1.Account) : async Nat {
      balance_.call_result(await* balance_.call());
    };
    
    public shared func transfer(_ : ICRC1.TransferArgs) : async ICRC1.TransferResult {
      transfer_.call_result(await* transfer_.call());
    };
    
    public shared func transfer_from(_ : ICRC1.TransferFromArgs) : async ICRC1.TransferFromResult {
      transfer_from_.call_result(await* transfer_from_.call());
    };
  };
};
