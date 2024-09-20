import ICRC1 "icrc1-api";
import R "mo:base/Result";
import ICRC84Helper "icrc84-helper";

module {

  public type DepositFromAllowanceError = ICRC1.TransferFromError or {
    #CallIcrc1LedgerError;
  };
  type DepositFromAllowanceResult = (credited : Nat, txid : Nat);
  public type DepositFromAllowanceResponse = R.Result<DepositFromAllowanceResult, DepositFromAllowanceError>;
  public type LogEvent = {
    #allowanceDrawn : { amount : Nat };
    #allowanceError : DepositFromAllowanceError;
  };

  public class AllowanceManager(
    icrc84 : ICRC84Helper.Ledger,
    surcharge : () -> Nat,
    changeCredit : ({ #pool; #user : Principal }, Int) -> (),
    log : (Principal, LogEvent) -> (),
    trap : (text : Text) -> (),
  ) {

    func fee() : Nat = icrc84.fee() + surcharge();

    /// Object to track all credit flows initiated from within DepositManager.
    /// The flow should never become negative.
    let credit = object {
      public var flow : Int = 0;
      public func change(who : { #user : Principal; #pool }, amount : Int) {
        changeCredit(who, amount);
        flow += amount;
        if (flow < 0) trap("credit flow went negative");
      };
    };

    /// Transfers the specified amount from the user's allowance to the service, crediting the user accordingly.
    /// This method allows a user to deposit tokens by setting up an allowance on their account with the service
    /// principal as the spender and then calling this method to transfer the allowed tokens.
    /// `amount` = credit-side amount.
    public func depositFromAllowance(p : Principal, source : ICRC1.Account, creditAmount : Nat, expectedFee : ?Nat) : async* DepositFromAllowanceResponse {
      switch (expectedFee) {
        case null {};
        case (?f) if (f != fee()) return #err(#BadFee { expected_fee = fee() });
      };

      let surcharge_ = surcharge();

      let res = await* icrc84.draw(p, source, creditAmount + fee());

      let event = switch (res) {
        case (#ok _) #allowanceDrawn({ amount = creditAmount });
        case (#err err) #allowanceError(err);
      };

      log(p, event);

      if (R.isOk(res)) {
        credit.change(#user p, creditAmount);
        credit.change(#pool, surcharge_);
      };

      switch (res) {
        case (#ok txid) #ok(creditAmount, txid);
        case (#err err) #err(err);
      };
    };
  };
};
