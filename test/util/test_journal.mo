import Array "mo:core/Array";
import Debug "mo:core/Debug";
import Iter "mo:core/Iter";
import Time "mo:core/Time";
import Int "mo:core/Int";
import Principal "mo:core/Principal";
import List "mo:core/List";
import Nat "mo:core/Nat";

import TokenHandler "../../src";

module {
  public class InveariantChecker() {
    var deposited = 0;
    var totalConsolidated = 0;
    var totalCredited = 0;
    var lockedFunds = 0;
    var totalWithdrawn = 0;

    var creditSum = 0;
    var handlerPool : Int = 0;
    var pool = 0;
    var fees = 0;

    public func checkInvariant(p : Principal, event : TokenHandler.LogEvent) : Bool {
      switch event {
        case (
          #newDeposit {
            depositInc;
            creditInc;
            ledgerFee;
            surcharge;
          }
        ) {
          deposited += depositInc;
          creditSum += creditInc;
          fees += ledgerFee;
          handlerPool += surcharge;
        };
        case (#depositInc(value)) {
          deposited += value;
          creditSum += value;
        };
        case (
          #consolidated {
            deducted;
            credited;
            fee;
          }
        ) {
          deposited -= deducted;
          totalConsolidated += credited;
          fees -= fee;
        };

        case (#credited value) {
          pool -= value;
          creditSum += value;
        };
        case (#debited value) {
          pool += value;
          creditSum -= value;
        };

        case (
          #feeUpdated {
            delta;
          }
        ) {
          handlerPool -= delta;
          assert fees + delta >= 0;
          fees := Int.abs(fees + delta);
        };
        case (#surchargeUpdated _) {};

        case (
          #allowanceDrawn {
            amount;
            credited;
            surcharge;
          }
        ) {
          totalCredited += amount;
          creditSum += credited;
          handlerPool += surcharge;
        };

        case (
          #withdraw {
            amount;
            withdrawn;
            surcharge;
          }
        ) {
          lockedFunds -= amount;
          totalWithdrawn += withdrawn;
          handlerPool += surcharge;
        };
        case (#locked value) {
          assert lockedFunds + value >= 0;
          lockedFunds := Int.abs(lockedFunds + value);

          if (p == Principal.fromBlob("")) {
            assert pool - value >= 0;
            pool := Int.abs(pool - value);
          } else {
            assert creditSum - value >= 0;
            creditSum := Int.abs(creditSum - value);
          };
        };

        case (#error _) {};
      };

      let assets = deposited + totalConsolidated + totalCredited - lockedFunds - totalWithdrawn : Nat;
      let liabilities = creditSum + handlerPool + pool + fees : Int;

      assets == liabilities;
    };
  };

  type JournalVector = List.List<(Time.Time, Principal, TokenHandler.LogEvent)>;

  public class TestJournal() {
    let journal : JournalVector = List.empty();
    let invariantChecker : InveariantChecker = InveariantChecker();

    var counter_ = 0;

    public func counter() : Nat = counter_;

    var verbose = false;

    public func verboseOn() = verbose := true;

    public func verboseOff() = verbose := false;

    public func log(p : Principal, e : TokenHandler.LogEvent) {
      let event = (Time.now(), p, e);
      if (verbose) Debug.print("logging: " # debug_show event);
      journal.add(event);
    };

    public func hasEvents(events : [TokenHandler.LogEvent]) : Bool {
      let prevCounter = counter_; // previous size
      counter_ := journal.size();
      if (counter_ != prevCounter + events.size()) return false;
      if (events.size() == 0) return true;
      for (i in Nat.range(prevCounter, prevCounter + events.size())) {
        let (_, p, event) = journal.at(i);
        if (event != events[i - prevCounter]) return false;
        if (not invariantChecker.checkInvariant(p, event)) return false;
      };
      true;
    };

    public func size() : Nat = journal.size();

    public func debugShow(startFrom : Nat) : () {
      Debug.print(
        debug_show (
          journal.toArray()
          |> Array.range(_, startFrom, _.size())
          |> Iter.toArray(_)
        )
      );
    };
  };
};
