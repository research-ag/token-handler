import Array "mo:base/Array";
import Error "mo:base/Error";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import Prim "mo:prim";
import Principal "mo:base/Principal";
import RBTree "mo:base/RBTree";
import Text "mo:base/Text";
import Timer "mo:base/Timer";

import ICRC1 "mo:mrr/TokenHandler/ICRC1";
import TokenHandler "mo:mrr/TokenHandler";
import Vec "mo:vector";

actor class Example(adminPrincipal_ : ?Principal) = self {

  stable var assetsData : Vec.Vector<StableAssetInfo> = Vec.new();

  stable var stableAdminsMap = RBTree.RBTree<Principal, ()>(Principal.compare).share();
  switch (RBTree.size(stableAdminsMap)) {
    case (0) {
      let adminsMap = RBTree.RBTree<Principal, ()>(Principal.compare);
      let ?ap = adminPrincipal_ else Prim.trap("Admin not provided");
      adminsMap.put(ap, ());
      stableAdminsMap := adminsMap.share();
    };
    case (_) {};
  };
  let adminsMap = RBTree.RBTree<Principal, ()>(Principal.compare);
  adminsMap.unshare(stableAdminsMap);

  type AssetInfo = {
    ledgerPrincipal : Principal;
    handler : TokenHandler.TokenHandler;
  };
  type StableAssetInfo = {
    ledgerPrincipal : Principal;
    handler : TokenHandler.StableData;
  };

  type TokenInfo = {
    min_deposit : Nat;
    min_withdrawal : Nat;
    deposit_fee : Nat;
    withdrawal_fee : Nat;
  };

  type NotifyResult = {
    #Ok : {
      deposit_inc : Nat;
      credit_inc : Nat;
    };
    #Err : {
      #CallLedgerError : Text;
      #NotAvailable : Text;
    };
  };

  type WithdrawResult = {
    #Ok : {
      txid : Nat;
      amount : Nat;
    };
    #Err : {
      #CallLedgerError : Text;
      #InsufficientCredit;
      #AmountBelowMinimum;
    };
  };

  let JOURNAL_SIZE = 1024;

  var initialized : Bool = false;
  var assets : Vec.Vector<AssetInfo> = Vec.new();

  private func assertInitialized() = if (not initialized) {
    Prim.trap("Not initialized");
  };

  public shared func init() : async () {
    assert not initialized;
    assets := Vec.map<StableAssetInfo, AssetInfo>(
      assetsData,
      func(x) {
        let r = (actor (Principal.toText(x.ledgerPrincipal)) : ICRC1.ICRC1Ledger)
        |> {
          balance_of = _.icrc1_balance_of;
          fee = _.icrc1_fee;
          transfer = _.icrc1_transfer;
        }
        |> {
          ledgerPrincipal = x.ledgerPrincipal;
          handler = TokenHandler.TokenHandler(_, Principal.fromActor(self), JOURNAL_SIZE, 0);
        };
        r.handler.unshare(x.handler);
        r;
      },
    );
    initialized := true;
  };

  public shared query func principalToSubaccount(p : Principal) : async ?Blob = async ?TokenHandler.toSubaccount(p);

  public shared query func icrcX_supported_tokens() : async [Principal] {
    assertInitialized();
    Array.tabulate<Principal>(
      Vec.size(assets),
      func(i) = Vec.get(assets, i).ledgerPrincipal,
    );
  };

  public shared query func icrcX_token_info(token : Principal) : async TokenInfo {
    assertInitialized();
    for ((assetInfo, i) in Vec.items(assets)) {
      if (Principal.equal(assetInfo.ledgerPrincipal, token)) {
        return assetInfo.handler.fee() |> {
          min_deposit = _ + 1;
          min_withdrawal = _ + 1;
          deposit_fee = _;
          withdrawal_fee = _;
        };
      };
    };
    throw Error.reject("Unknown token");
  };

  public shared query ({ caller }) func icrcX_credit(token : Principal) : async Int {
    assertInitialized();
    switch (getAssetInfo(token)) {
      case (?info) info.handler.getCredit(caller);
      case (_) 0;
    };
  };

  public shared query ({ caller }) func icrcX_all_credits() : async [(Principal, Int)] {
    assertInitialized();
    let res : Vec.Vector<(Principal, Int)> = Vec.new();
    for (assetInfo in Vec.vals(assets)) {
      let credit = assetInfo.handler.getCredit(caller);
      if (credit != 0) {
        Vec.add(res, (assetInfo.ledgerPrincipal, credit));
      };
    };
    Vec.toArray(res);
  };

  public shared query ({ caller }) func icrcX_trackedDeposit(token : Principal) : async {
    #Ok : Nat;
    #Err : { #NotAvailable : Text };
  } {
    assertInitialized();
    (
      switch (getAssetInfo(token)) {
        case (?aid) aid;
        case (_) return #Err(#NotAvailable("Unknown token"));
      }
    )
    |> _.handler.trackedDeposit(caller)
    |> (
      switch (_) {
        case (?d) #Ok(d);
        case (null) #Err(#NotAvailable("Unknown caller"));
      }
    );
  };

  public shared ({ caller }) func icrcX_notify(args : { token : Principal }) : async NotifyResult {
    assertInitialized();
    let assetInfo = switch (getAssetInfo(args.token)) {
      case (?aid) aid;
      case (_) return #Err(#NotAvailable("Unknown token"));
    };
    let result = try {
      ignore await* assetInfo.handler.fetchFee();
      await* assetInfo.handler.notify(caller);
    } catch (err) {
      return #Err(#CallLedgerError(Error.message(err)));
    };
    switch (result) {
      case (?(delta, usableBalance)) {
        await* assetInfo.handler.trigger();
        #Ok({ deposit_inc = delta; credit_inc = delta });
      };
      case (null) {
        #Ok({
          deposit_inc = 0;
          credit_inc = 0;
        });
      };
    };
  };

  public shared ({ caller }) func icrcX_withdraw(args : { to_subaccount : ?Blob; amount : Nat; token : Principal }) : async WithdrawResult {
    assertInitialized();
    let ?assetInfo = getAssetInfo(args.token) else throw Error.reject("Unknown token");
    if (not assetInfo.handler.debitStrict(caller, args.amount)) {
      return #Err(#InsufficientCredit);
    };
    let res = await* assetInfo.handler.withdraw({ owner = caller; subaccount = args.to_subaccount }, args.amount);
    switch (res) {
      case (#ok(txid, amount)) #Ok({ txid; amount });
      case (#err err) {
        assetInfo.handler.credit(caller, args.amount);
        switch (err) {
          case (#TooLowQuantity) #Err(#AmountBelowMinimum);
          case (#CallIcrc1LedgerError) #Err(#CallLedgerError("Call error"));
          case (_) #Err(#CallLedgerError("Try later"));
        };
      };
    };
  };

  // A timer for consolidating backlog subaccounts
  ignore Timer.recurringTimer<system>(
    #seconds 60,
    func() : async () {
      for (asset in Vec.vals(assets)) {
        await* asset.handler.trigger();
      };
    },
  );

  private func getAssetInfo(icrc1Ledger : Principal) : ?AssetInfo {
    for (assetInfo in Vec.vals(assets)) {
      if (Principal.equal(assetInfo.ledgerPrincipal, icrc1Ledger)) {
        return ?assetInfo;
      };
    };
    return null;
  };

  public query func listAdmins() : async [Principal] = async adminsMap.entries()
  |> Iter.map<(Principal, ()), Principal>(_, func((p, _)) = p)
  |> Iter.toArray(_);

  private func assertAdminAccess(principal : Principal) : async* () {
    if (adminsMap.get(principal) == null) {
      throw Error.reject("No Access for this principal " # Principal.toText(principal));
    };
  };

  public shared ({ caller }) func addAdmin(principal : Principal) : async () {
    await* assertAdminAccess(caller);
    adminsMap.put(principal, ());
  };

  public shared ({ caller }) func removeAdmin(principal : Principal) : async () {
    if (Principal.equal(principal, caller)) {
      throw Error.reject("Cannot remove yourself from admins");
    };
    await* assertAdminAccess(caller);
    adminsMap.delete(principal);
  };

  public shared ({ caller }) func registerAsset(ledger : Principal) : async {
    #Ok : Nat;
    #Err : { #AlreadyRegistered : Nat };
  } {
    assertInitialized();
    await* assertAdminAccess(caller);
    // validate ledger
    let canister = actor (Principal.toText(ledger)) : (actor { icrc1_metadata : () -> async [Any] });
    try {
      ignore await canister.icrc1_metadata();
    } catch (err) {
      throw err;
    };
    for ((assetInfo, i) in Vec.items(assets)) {
      if (Principal.equal(ledger, assetInfo.ledgerPrincipal)) return #Err(#AlreadyRegistered(i));
    };
    let id = Vec.size(assets);
    (actor (Principal.toText(ledger)) : ICRC1.ICRC1Ledger)
    |> {
      balance_of = _.icrc1_balance_of;
      fee = _.icrc1_fee;
      transfer = _.icrc1_transfer;
    }
    |> {
      ledgerPrincipal = ledger;
      handler = TokenHandler.TokenHandler(_, Principal.fromActor(self), JOURNAL_SIZE, 0);
    }
    |> Vec.add<AssetInfo>(assets, _);
    #Ok(id);
  };

  system func preupgrade() {
    assetsData := Vec.map<AssetInfo, StableAssetInfo>(
      assets,
      func(x) = {
        ledgerPrincipal = x.ledgerPrincipal;
        handler = x.handler.share();
      },
    );
    stableAdminsMap := adminsMap.share();
  };

};
