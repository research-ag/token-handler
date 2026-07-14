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
import TokenHandlerContext "TokenHandlerContext";

module {

  /// Module `TokenHandler` provides mechanisms to facilitate the deposit and withdrawal management on an ICRC-1 ledger.
  ///
  /// Key features include subaccount management, deposit notifications, credit registry, and withdrawal mechanisms,
  /// providing a comprehensive solution for handling ICRC-1 token transactions.
  public type TokenHandler = {
    var isFrozen_ : Bool;
    ledger : ICRC84Helper.Ledger;
    data : Data.Data<Principal>;
    feeManager : FeeManager.FeeManager;
    creditManager : CreditManager.CreditManager;
    depositManager : DepositManager.DepositManager;
    allowanceManager : AllowanceManager.AllowanceManager;
    withdrawalManager : WithdrawalManager.WithdrawalManager;
    triggerOnNotifications : Bool;
    ownPrincipal : Principal;
    log : (Principal, LogEvent) -> ();
  };

  public type StableData = {
    data : Data.Data<Principal>;
    depositManager : DepositManager.DepositManager;
    creditManager : CreditManager.CreditManager;
    feeManager : FeeManager.FeeManager;
    ledger : ICRC84Helper.Ledger;
    withdrawalManager : WithdrawalManager.WithdrawalManager;
    allowanceManager : AllowanceManager.AllowanceManager;
  };

  public type LogEvent = DepositManager.LogEvent or AllowanceManager.LogEvent or WithdrawalManager.LogEvent or CreditManager.LogEvent or FeeManager.LogEvent or {
    #error : Text;
  };

  public type TokenHandlerOptions = {
    ownPrincipal : Principal;
    initialFee : Nat;
    triggerOnNotifications : Bool;
    log : (Principal, LogEvent) -> ();
  };

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

  public func new(options : TokenHandlerOptions) : TokenHandler {
    let ledger = ICRC84Helper.Ledger(options.ownPrincipal, options.initialFee);
    let data = Data.empty<Principal>();
    let feeManager = FeeManager.new();
    let creditManager = CreditManager.new();
    let depositManager = DepositManager.new();
    let allowanceManager = AllowanceManager.new();
    let withdrawalManager = WithdrawalManager.new();

    let self : TokenHandler = {
      var isFrozen_ = false;
      ledger;
      data;
      feeManager;
      creditManager;
      depositManager;
      allowanceManager;
      withdrawalManager;
      triggerOnNotifications = options.triggerOnNotifications;
      ownPrincipal = options.ownPrincipal;
      log = options.log;
    };

    self;
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
  func freezeTokenHandler(self : TokenHandler, errorText : Text) : () {
    self.isFrozen_ := true;
    self.log(self.ownPrincipal, #error(errorText));
  };

  /// Returns the ledger fee.
  public func ledgerFee(self : TokenHandler) : Nat = self.feeManager.ledgerFee(self.ledger);

  /// Returns the current surcharge amount.
  public func surcharge(self : TokenHandler) : Nat = self.feeManager.surcharge;

  /// Sets new surcharge amount.
  public func setSurcharge(self : TokenHandler, s : Nat) = self.feeManager.setSurcharge(s, self.log);

  /// Calculates the final fee of the specific type.
  public func fee(self : TokenHandler, _ : { #deposit; #allowance; #withdrawal }) : Nat = self.feeManager.fee(self.ledger);

  /// Fetches and updates the fee from the ICRC1 ledger.
  /// Returns the new fee, or `null` if fetching is already in progress.
  public func fetchFee(self : TokenHandler, ctx : TokenHandlerContext.TokenHandlerContext) : async* ?Nat {
    if (self.isFrozen_) Runtime.trap("The token handler is frozen");
    let ret = await* ICRC84Helper.loadFee(self.ledger, ctx.api, func() = assertInvariant(self), func(oldFee, newFee) = onFeeChanged(self, oldFee, newFee));
    ignore assertInvariant(self);
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
  public func creditUser(self : TokenHandler, p : Principal, amount : Nat) : Bool {
    if (self.isFrozen_) Runtime.trap("The token handler is frozen");
    let ret = self.creditManager.creditUser(self.data, self.log, p, amount);
    ignore assertInvariant(self);
    ret;
  };

  /// Deducts amount from P’s credit.
  /// With checking the availability of sufficient funds in the pool.
  public func debitUser(self : TokenHandler, p : Principal, amount : Nat) : Bool {
    if (self.isFrozen_) Runtime.trap("The token handler is frozen");
    let ret = self.creditManager.debitUser(self.data, self.log, p, amount);
    ignore assertInvariant(self);
    ret;
  };

  /// Notifies of a deposit and schedules consolidation process.
  /// Returns the newly detected deposit and credit funds if successful, otherwise `null`.
  public func notify(self : TokenHandler, p : Principal, ctx : TokenHandlerContext.TokenHandlerContext) : async* ?(Nat, Nat) {
    if (self.isFrozen_) return null;
    let ?result = await* DepositManager.notify(
      self.depositManager,
      self.ledger,
      self.data,
      self.feeManager,
      self.log,
      func(err) { freezeTokenHandler(self, err) },
      self.triggerOnNotifications,
      p,
      ctx.api,
      func() = assertInvariant(self),
      func(oldFee, newFee) = onFeeChanged(self, oldFee, newFee),
    ) else return null;
    ignore assertInvariant(self);
    ?result;
  };

  /// Transfers the specified amount from the user's allowance to the service, crediting the user accordingly.
  public func depositFromAllowance(
    self : TokenHandler,
    p : Principal,
    source : ICRC1.Account,
    amount : Nat,
    expectedFee : ?Nat,
    ctx : TokenHandlerContext.TokenHandlerContext,
  ) : async* AllowanceManager.DepositFromAllowanceResponse {
    if (self.isFrozen_) Runtime.trap("The token handler is frozen");
    let ret = await* AllowanceManager.depositFromAllowance(
      self.allowanceManager,
      self.ledger,
      self.data,
      self.feeManager,
      self.log,
      p,
      source,
      amount,
      expectedFee,
      ctx.api,
      func() = assertInvariant(self),
      func(oldFee, newFee) = onFeeChanged(self, oldFee, newFee),
    );
    ignore assertInvariant(self);
    ret;
  };

  /// Triggers the processing deposits.
  /// n - desired number of potential consolidations.
  public func trigger(self : TokenHandler, n : Nat, ctx : TokenHandlerContext.TokenHandlerContext) : async* () {
    if (self.isFrozen_) return;
    await* DepositManager.trigger(
      self.depositManager,
      self.ledger,
      self.data,
      self.feeManager,
      self.log,
      n,
      ctx.api,
      func() = assertInvariant(self),
      func(oldFee, newFee) = onFeeChanged(self, oldFee, newFee),
    );
    ignore assertInvariant(self);
  };

  /// Initiates a withdrawal by transferring tokens to another account.
  /// Returns ICRC1 transaction index and amount of transferred tokens (fee excluded).
  /// At the same time, it reduces the pool credit. Accordingly, amount <= credit should be satisfied.
  public func withdrawFromPool(
    self : TokenHandler,
    to : ICRC1.Account,
    amount : Nat,
    expectedFee : ?Nat,
    ctx : TokenHandlerContext.TokenHandlerContext,
  ) : async* WithdrawalManager.WithdrawResponse {
    if (self.isFrozen_) Runtime.trap("The token handler is frozen");
    let ret = await* WithdrawalManager.withdraw(
      self.withdrawalManager,
      self.ledger,
      self.data,
      self.creditManager,
      self.feeManager,
      self.log,
      null,
      to,
      amount,
      expectedFee,
      ctx.api,
      func() = assertInvariant(self),
      func(oldFee, newFee) = onFeeChanged(self, oldFee, newFee),
    );
    ignore assertInvariant(self);
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
    ctx : TokenHandlerContext.TokenHandlerContext,
  ) : async* WithdrawalManager.WithdrawResponse {
    if (self.isFrozen_) Runtime.trap("The token handler is frozen");
    let ret = await* WithdrawalManager.withdraw(
      self.withdrawalManager,
      self.ledger,
      self.data,
      self.creditManager,
      self.feeManager,
      self.log,
      ?p,
      to,
      creditAmount,
      expectedFee,
      ctx.api,
      func() = assertInvariant(self),
      func(oldFee, newFee) = onFeeChanged(self, oldFee, newFee),
    );
    ignore assertInvariant(self);
    ret;
  };

  public func assertInvariant(self : TokenHandler) : Bool {
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
    if (not ok) freezeTokenHandler(self, "Invariant violation: assets != liabilities");
    ok;
  };

  func onFeeChanged(self : TokenHandler, oldFee : Nat, newFee : Nat) : () {
    self.data.thresholdChanged(newFee);
    self.feeManager.onFeeChanged(self.data, oldFee, newFee, self.log);
  };

  /// Serializes the token handler data.
  public func share(self : TokenHandler) : StableData = {
    data = self.data;
    creditManager = self.creditManager;
    depositManager = self.depositManager;
    feeManager = self.feeManager;
    ledger = self.ledger;
    withdrawalManager = self.withdrawalManager;
    allowanceManager = self.allowanceManager;
  };

  /// Deserializes the token handler data.
  public func unshare(self : TokenHandler, values : StableData) {
    self.data.tree := values.data.tree;
    self.data.depositsTree := values.data.depositsTree;
    self.data.handlerPool := values.data.handlerPool;
    self.data.lookupCount_ := values.data.lookupCount_;
    self.data.size_ := values.data.size_;
    self.data.locks_ := values.data.locks_;
    self.data.credit_sum := values.data.credit_sum;
    self.data.deposits_count := values.data.deposits_count;
    self.data.deposit_sum := values.data.deposit_sum;
    self.data.unusable_deposit.correct := values.data.unusable_deposit.correct;
    self.data.unusable_deposit.sum := values.data.unusable_deposit.sum;
    self.creditManager.pool := values.creditManager.pool;
    self.depositManager.totalConsolidated := values.depositManager.totalConsolidated;
    self.depositManager.paused := values.depositManager.paused;
    self.depositManager.totalCredited := values.depositManager.totalCredited;
    self.depositManager.underwayFunds := values.depositManager.underwayFunds;
    self.feeManager.surcharge := values.feeManager.surcharge;
    self.feeManager.outstandingFees := values.feeManager.outstandingFees;

    self.ledger.fee := values.ledger.fee;
    self.ledger.feeLock := values.ledger.feeLock;
    self.ledger.ownPrincipal := values.ledger.ownPrincipal;

    self.withdrawalManager.totalWithdrawn := values.withdrawalManager.totalWithdrawn;
    self.withdrawalManager.lockedFunds := values.withdrawalManager.lockedFunds;
    self.allowanceManager.totalCredited := values.allowanceManager.totalCredited;
  };
};
