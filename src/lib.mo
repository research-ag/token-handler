/// TokenHandler
///
/// Copyright: 2023 - 2025 MR Research AG
///
/// Main author: Timo Hanke (timohanke)
///
/// Contributors: Andrii Stepanov (AStepanov25), Denys Kushnarov (reginleif888), Andy Gura (AndyGura)

import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Prim "mo:prim";

import ICRC84 "mo:icrc-84";

import AllowanceManager "AllowanceManager";
import CreditManager "CreditManager";
import { Data; Entry } "Data";
import DepositManager "DepositManager";
import FeeManager "FeeManager";
import ICRC1 "icrc1-api";
import ICRC84Helper "icrc84-helper";
import WithdrawalManager "WithdrawalManager";
import Types "types";

module {

  /// Module `TokenHandler` provides mechanisms to facilitate the deposit and withdrawal management on an ICRC-1 ledger.
  ///
  /// Key features include subaccount management, deposit notifications, credit registry, and withdrawal mechanisms,
  /// providing a comprehensive solution for handling ICRC-1 token transactions.
  public type TokenHandler = Types.TokenHandler;

  public type LogEvent = Types.LogEvent;

  public type State = {
    balance : {
      deposited : Nat;
      underway : Nat;
      queued : Nat;
      consolidated : Nat;
      usableDeposit : (deposit : Int, correct : Bool);
    };
    flow : {
      consolidated : Nat;
      withdrawn : Nat;
    };
    credit : {
      total : Int;
      pool : Int;
    };
    users : {
      queued : Nat;
      locked : Nat;
      total : Nat;
    };
    depositManager : DepositManager.State;
    withdrawalManager : WithdrawalManager.State;
    feeManager : FeeManager.State;
  };

  /// Converts `Principal` to `ICRC1.Subaccount`.
  public func toSubaccount(p : Principal) : ICRC1.Subaccount = ICRC84.toSubaccount(p);

  /// Converts `ICRC1.Subaccount` to `Principal`.
  public func toPrincipal(subaccount : ICRC1.Subaccount) : ?Principal = ICRC84.toPrincipal(subaccount);

  public type LedgerAPI = ICRC1.API;

  /// Build a `LedgerAPI` object based on the ledger principal.
  public func buildLedgerApi(ledgerPrincipal : Principal) : LedgerAPI {
    Prim.actorOfPrincipal<ICRC1.Service>(ledgerPrincipal)
    |> ICRC1.apiFromService(_);
  };

  public func new(
    options : {
      ownPrincipal : Principal;
      initialFee : Nat;
      triggerOnNotifications : Bool;
    }
  ) : TokenHandler = {
    ledger = ICRC84Helper.Ledger(options.initialFee);
    data = Data.empty<Principal>();
    feeManager = FeeManager.new();
    creditManager = CreditManager.new();
    depositManager = DepositManager.new();
    allowanceManager = AllowanceManager.new();
    withdrawalManager = WithdrawalManager.new();
    var triggerOnNotifications = options.triggerOnNotifications;
    ownPrincipal = options.ownPrincipal;
    var isFrozen_ = false;
  };

  /// Returns `true` when new notifications are paused.
  public func notificationsOnPause(self : TokenHandler) : Bool = self.depositManager.state(self.data).paused;

  /// Pause new notifications.
  public func pauseNotifications(self : TokenHandler) {
    if (self.isFrozen_) Runtime.trap("The token handler is frozen");
    self.depositManager.pause(true);
  };

  /// Unpause new notifications.
  public func unpauseNotifications(self : TokenHandler) {
    if (self.isFrozen_) Runtime.trap("The token handler is frozen");
    self.depositManager.pause(false);
  };

  /// Checks if the TokenHandler is frozen.
  public func isFrozen(self : TokenHandler) : Bool = self.isFrozen_;

  /// Freezes the handler in case of unexpected errors and logs the error message to the journal.
  func freezeTokenHandler(self : TokenHandler, errorText : Text, ctx : Types.TokenHandlerContext) : () {
    self.isFrozen_ := true;
    ctx.log(self.ownPrincipal, #error(errorText));
  };

  /// Returns the ledger fee.
  public func ledgerFee(self : TokenHandler) : Nat = self.feeManager.ledgerFee(self.ledger);

  /// Returns the current surcharge amount.
  public func surcharge(self : TokenHandler) : Nat = self.feeManager.surcharge;

  /// Sets new surcharge amount.
  public func setSurcharge(self : TokenHandler, s : Nat, ctx : Types.TokenHandlerContext) = self.feeManager.setSurcharge(s, ctx);

  /// Calculates the final fee of the specific type.
  public func fee(self : TokenHandler, _ : { #deposit; #allowance; #withdrawal }) : Nat = self.feeManager.fee(self.ledger);

  /// Fetches and updates the fee from the ICRC1 ledger.
  /// Returns the new fee, or `null` if fetching is already in progress.
  public func fetchFee(self : TokenHandler, ctx : Types.TokenHandlerContext) : async* ?Nat {
    if (self.isFrozen_) Runtime.trap("The token handler is frozen");
    let ret = await* ICRC84Helper.loadFee(self.ledger, ctx);
    ignore ctx.assertInvariant();
    ret;
  };

  /// Returns a user's last know (= tracked) deposit
  /// Null means the principal is locked, hence no value is available.
  public func trackedDeposit(self : TokenHandler, p : Principal) : ?Nat = switch (self.data.get(p)) {
    case null null;
    case (?entry) ?entry.deposit();
  };

  /// Returns the current `TokenHandler` state.
  public func state(self : TokenHandler) : State {
    let d = self.depositManager.state(self.data);
    let w = self.withdrawalManager.state();
    {
      balance = {
        deposited = d.funds.deposited;
        underway = d.funds.underway;
        queued = d.funds.queued;
        consolidated = d.totalConsolidated - w.totalWithdrawn;
        usableDeposit = self.data.usableDeposit();
      };
      flow = {
        consolidated = d.totalConsolidated;
        withdrawn = w.totalWithdrawn;
      };
      credit = {
        total = self.data.creditSum() + self.data.handlerPoolBalance();
        pool = self.data.handlerPoolBalance();
      };
      users = {
        queued = self.data.depositsCount();
        locked = self.data.locks();
        total = self.data.size();
      };
      depositManager = d;
      withdrawalManager = w;
      feeManager = self.feeManager.state(self.ledger);
    };
  };

  /// Gets the current credit amount associated with a specific principal.
  public func userCredit(self : TokenHandler, p : Principal) : Nat = self.data.entry(p).credit();

  /// Gets the current credit amount in the pool.
  public func handlerCredit(self : TokenHandler) : Int = self.data.handlerPoolBalance();

  public func poolCredit(self : TokenHandler) : Nat = self.creditManager.poolBalance();

  /// Adds amount to P’s credit.
  /// With checking the availability of sufficient funds.
  public func creditUser(self : TokenHandler, p : Principal, amount : Nat, ctx : Types.TokenHandlerContext) : Bool {
    if (self.isFrozen_) Runtime.trap("The token handler is frozen");
    let ret = self.creditManager.creditUser(self.data, p, amount, ctx);
    ignore ctx.assertInvariant();
    ret;
  };

  /// Deducts amount from P’s credit.
  /// With checking the availability of sufficient funds in the pool.
  public func debitUser(self : TokenHandler, p : Principal, amount : Nat, ctx : Types.TokenHandlerContext) : Bool {
    if (self.isFrozen_) Runtime.trap("The token handler is frozen");
    let ret = self.creditManager.debitUser(self.data, p, amount, ctx);
    ignore ctx.assertInvariant();
    ret;
  };

  /// Notifies of a deposit and schedules consolidation process.
  /// Returns the newly detected deposit and credit funds if successful, otherwise `null`.
  public func notify(self : TokenHandler, p : Principal, ctx : Types.TokenHandlerContext) : async* ?(Nat, Nat) {
    if (self.isFrozen_) return null;
    let ?result = await* DepositManager.notify(
      self.depositManager,
      self.ledger,
      self.data,
      self.feeManager,
      func(err) { freezeTokenHandler(self, err, ctx) },
      self.triggerOnNotifications,
      p,
      ctx,
    ) else return null;
    ignore ctx.assertInvariant();
    ?result;
  };

  /// Transfers the specified amount from the user's allowance to the service, crediting the user accordingly.
  public func depositFromAllowance(
    self : TokenHandler,
    p : Principal,
    source : ICRC1.Account,
    amount : Nat,
    expectedFee : ?Nat,
    ctx : Types.TokenHandlerContext,
  ) : async* AllowanceManager.DepositFromAllowanceResponse {
    if (self.isFrozen_) Runtime.trap("The token handler is frozen");
    let ret = await* AllowanceManager.depositFromAllowance(
      self.allowanceManager,
      self.ledger,
      self.data,
      self.feeManager,
      p,
      source,
      amount,
      expectedFee,
      ctx,
    );
    ignore ctx.assertInvariant();
    ret;
  };

  /// Triggers the processing deposits.
  /// n - desired number of potential consolidations.
  public func trigger(self : TokenHandler, n : Nat, ctx : Types.TokenHandlerContext) : async* () {
    if (self.isFrozen_) return;
    await* DepositManager.trigger(
      self.depositManager,
      self.ledger,
      self.data,
      self.feeManager,
      n,
      ctx,
    );
    ignore ctx.assertInvariant();
  };

  /// Initiates a withdrawal by transferring tokens to another account.
  /// Returns ICRC1 transaction index and amount of transferred tokens (fee excluded).
  /// At the same time, it reduces the pool credit. Accordingly, amount <= credit should be satisfied.
  public func withdrawFromPool(
    self : TokenHandler,
    to : ICRC1.Account,
    amount : Nat,
    expectedFee : ?Nat,
    ctx : Types.TokenHandlerContext,
  ) : async* WithdrawalManager.WithdrawResponse {
    if (self.isFrozen_) Runtime.trap("The token handler is frozen");
    let ret = await* WithdrawalManager.withdraw(
      self.withdrawalManager,
      self.ledger,
      self.data,
      self.creditManager,
      self.feeManager,
      null,
      to,
      amount,
      expectedFee,
      ctx,
    );
    ignore ctx.assertInvariant();
    ret;
  };

  /// Initiates a withdrawal by transferring tokens to another account.
  /// Returns ICRC1 transaction index and amount of transferred tokens (fee excluded).
  /// At the same time, it reduces the user's credit. Accordingly, amount <= credit should be satisfied.
  public func withdrawFromCredit(
    self : TokenHandler,
    p : Principal,
    to : ICRC1.Account,
    creditAmount : Nat,
    expectedFee : ?Nat,
    ctx : Types.TokenHandlerContext,
  ) : async* WithdrawalManager.WithdrawResponse {
    if (self.isFrozen_) Runtime.trap("The token handler is frozen");
    let ret = await* WithdrawalManager.withdraw(
      self.withdrawalManager,
      self.ledger,
      self.data,
      self.creditManager,
      self.feeManager,
      ?p,
      to,
      creditAmount,
      expectedFee,
      ctx,
    );
    ignore assertInvariant(self, ctx);
    ret;
  };

  public func assertInvariant(self : TokenHandler, ctx : Types.TokenHandlerContext) : Bool {
    let { totalConsolidated; funds = { deposited } } = self.depositManager.state(self.data);
    let { totalWithdrawn; lockedFunds } = self.withdrawalManager.state();
    let { totalCredited } = self.allowanceManager.state();
    let assets = deposited + totalConsolidated + totalCredited - lockedFunds - totalWithdrawn : Nat;

    let creditSum = self.data.creditSum();
    let handlerPool = self.data.handlerPoolBalance();
    let pool = self.creditManager.poolBalance();
    let { outstandingFees } = self.feeManager.state(self.ledger);
    let liabilities = creditSum + handlerPool + pool + outstandingFees : Int;

    let ok = assets == liabilities;
    if (not ok) freezeTokenHandler(self, "Invariant violation: assets != liabilities", ctx);
    ok;
  };

  public func onFeeChanged(self : TokenHandler, oldFee : Nat, newFee : Nat, ctx : Types.TokenHandlerContext) : () {
    self.data.thresholdChanged(newFee);
    self.feeManager.onFeeChanged(self.data, oldFee, newFee, ctx);
  };
};
