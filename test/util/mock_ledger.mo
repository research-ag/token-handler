import ICRC1 "../../src/icrc1-api";
import AsyncTester "mo:await-async";

module {
  public class MockLedger(debug_ : Bool, key : Text) {
    public let fee_ = AsyncTester.SimpleStageTester<Nat>(?(key # " fee"), null, debug_);
    public let balance_ = AsyncTester.SimpleStageTester<Nat>(?(key # " balance"), null, debug_);
    public let transfer_ = AsyncTester.SimpleStageTester<ICRC1.TransferResult>(?(key # " transfer"), null, debug_);
    public let transfer_from_ = AsyncTester.SimpleStageTester<ICRC1.TransferFromResult>(?(key # " transfer_from"), null, debug_);
    
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