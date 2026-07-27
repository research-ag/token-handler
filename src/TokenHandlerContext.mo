import ICRC1 "icrc1-api";
import Types "types";
import TokenHandler "lib";

// A transient type for TokenHandler callbacks, shared functions, API
module {

  public func new(
    handler : TokenHandler.TokenHandler,
    ledgerApi : ICRC1.API,
    log : (Principal, Types.LogEvent) -> (),
  ) : Types.TokenHandlerContext {
    let ctx = {
      ownPrincipal = handler.ownPrincipal;
      api = ledgerApi;
      assertInvariant = func() : Bool = handler.assertInvariant(ctx);
      onFeeChanged = func(oldFee : Nat, newFee : Nat) = handler.onFeeChanged(oldFee : Nat, newFee : Nat, ctx);
      log = log;
      var isFrozen_ = false;
    };
    return ctx;
  };

};
