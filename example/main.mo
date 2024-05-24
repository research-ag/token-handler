import Array "mo:base/Array";
import Error "mo:base/Error";
import Int "mo:base/Int";
import Prim "mo:prim";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Timer "mo:base/Timer";
import Vec "mo:vector";

import ICRC1 "../src/ICRC1";
import TokenHandler "../src";

actor class Example() = self {

  stable var assetsData : Vec.Vector<StableAssetInfo> = Vec.new();

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
          transfer_from = _.icrc2_transfer_from;
        }
        |> {
          ledgerPrincipal = x.ledgerPrincipal;
          handler = TokenHandler.TokenHandler(_, Principal.fromActor(self), JOURNAL_SIZE, 0, true);
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
        return {
          min_deposit = assetInfo.handler.minimum(#deposit);
          min_withdrawal = assetInfo.handler.minimum(#withdrawal);
          deposit_fee = assetInfo.handler.fee(#deposit);
          withdrawal_fee = assetInfo.handler.fee(#withdrawal);
        };
      };
    };
    throw Error.reject("Unknown token");
  };

  public shared query ({ caller }) func icrcX_credit(token : Principal) : async Int {
    assertInitialized();
    switch (getAssetInfo(token)) {
      case (?info) info.handler.userCredit(caller);
      case (_) 0;
    };
  };

  public shared query ({ caller }) func icrcX_all_credits() : async [(Principal, Int)] {
    assertInitialized();
    let res : Vec.Vector<(Principal, Int)> = Vec.new();
    for (assetInfo in Vec.vals(assets)) {
      let credit = assetInfo.handler.userCredit(caller);
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
        await* assetInfo.handler.trigger(1);
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
    let res = await* assetInfo.handler.withdrawFromCredit(caller, { owner = caller; subaccount = args.to_subaccount }, args.amount);
    switch (res) {
      case (#ok(txid, amount)) #Ok({ txid; amount });
      case (#err err) {
        switch (err) {
          case (#InsufficientCredit) #Err(#InsufficientCredit);
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
        await* asset.handler.trigger(1);
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

  public shared func registerAsset(ledger : Principal) : async {
    #Ok : Nat;
    #Err : { #AlreadyRegistered : Nat };
  } {
    assertInitialized();
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
      transfer_from = _.icrc2_transfer_from;
    }
    |> {
      ledgerPrincipal = ledger;
      handler = TokenHandler.TokenHandler(_, Principal.fromActor(self), JOURNAL_SIZE, 0, true);
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
  };
};
