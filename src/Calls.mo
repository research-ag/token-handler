import ICRC1 "icrc1-api";
import ICRC1Agent "icrc1-agent";
import ICRC84 "mo:icrc84";

module {
  type BalanceResult = ICRC1Agent.BalanceResult;
  type TransferResult = ICRC1Agent.TransferResult;
  type DrawResult = ICRC1Agent.TransferFromResult;

  public class Ledger(api : ICRC1.API, ownPrincipal : Principal) {
    let agent = ICRC1Agent.LedgerAgent(api);
    public func fee() : Nat = agent.fee();
    public func setFee(x : Nat) = agent.setFee(x);

    /// Fetches actual deposit for a principal from the ICRC1 ledger.
    public func loadDeposit(p : Principal) : async* BalanceResult {
      await* agent.balance_of({
        owner = ownPrincipal;
        subaccount = ?ICRC84.toSubaccount(p);
      });
    };

    // Amount is the amount to transfer out, amount - fee is received
    func transfer(from_subaccount : ?ICRC1.Subaccount, to : ICRC1.Account, amount : Nat) : async* TransferResult {
      let fee = agent.fee();
      assert amount >= fee;
      await* agent.transfer(from_subaccount, to, amount - fee);
    };

    /// Consolidate funds into the main account
    public func consolidate(p : Principal, amount : Nat) : async* TransferResult {
      await* agent.transfer(
        ?ICRC84.toSubaccount(p),
        { owner = ownPrincipal; subaccount = null },
        amount,
      );
    };

    /// Send <amount> out from the main account, <amount> - fee_ will be received
    public func send(to : ICRC1.Account, amount : Nat) : async* TransferResult {
      await* transfer(null, to, amount);
    };

    /// Draw <amount> from an allowance into the main account
    /// <amount> will be received
    public func draw(p : Principal, from : ICRC1.Account, amount : Nat) : async* DrawResult {
      // TODO: change amount to amount - fee
      // let fee = agent.fee();
      // assert amount >= fee;
      let to = { owner = ownPrincipal; subaccount = null };
      await* agent.transfer_from(from, to, amount, ?ICRC84.toSubaccount(p));
    };

  };
};
