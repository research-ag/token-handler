import ICRC1 "icrc1-api";
import R "mo:base/Result";
import Principal "mo:base/Principal";
import ICRC84Helper "icrc84-helper";
import Data "Data";
import FeeManager "FeeManager";
import CreditManager "CreditManager";

module {
  public type DepositFromAllowanceError = ICRC1.TransferFromError or {
    #CallIcrc1LedgerError;
  };

  type DepositFromAllowanceResult = (credited : Nat, txid : Nat);

  public type DepositFromAllowanceResponse = R.Result<DepositFromAllowanceResult, DepositFromAllowanceError>;

  public type LogEvent = {
    #allowanceDrawn : { amount : Nat };
    #allowanceError : DepositFromAllowanceError;
    #issued : Int;
  };

  public class AllowanceManager(
    icrc84 : ICRC84Helper.Ledger,
    map : Data.Map<Principal>,
    creditManager : CreditManager.CreditManager,
    feeManager : FeeManager.FeeManager,
    log : (Principal, LogEvent) -> (),
  ) {
    /// Transfers the specified amount from the user's allowance to the service, crediting the user accordingly.
    /// This method allows a user to deposit tokens by setting up an allowance on their account with the service
    /// principal as the spender and then calling this method to transfer the allowed tokens.
    /// `amount` = credit-side amount.
    public func depositFromAllowance(p : Principal, source : ICRC1.Account, creditAmount : Nat, expectedFee : ?Nat) : async* DepositFromAllowanceResponse {
      switch (expectedFee) {
        case null {};
        case (?f) if (f != feeManager.fee()) {
          let err = #BadFee { expected_fee = feeManager.fee() };
          log(p, #allowanceError err);
          return #err(err);
        };
      };

      let surcharge_ = feeManager.surcharge();

      let res = await* icrc84.draw(p, source, creditAmount + feeManager.fee());

      let event = switch (res) {
        case (#ok _) #allowanceDrawn { amount = creditAmount };
        case (#err err) #allowanceError err;
      };

      log(p, event);

      if (R.isOk(res)) {
        assert map.get(p).changeCredit(creditAmount);
        log(p, #issued(creditAmount));
        assert creditManager.changePool(surcharge_);
        log(Principal.fromBlob(""), #issued(surcharge_));
      };

      switch (res) {
        case (#ok txid) #ok(creditAmount, txid);
        case (#err err) #err(err);
      };
    };
  };
};
