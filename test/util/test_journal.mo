import Array "mo:base/Array";
import Debug "mo:base/Debug";
import Iter "mo:base/Iter";
import Time "mo:base/Time";
import Vec "mo:vector";

import TokenHandler "../../src";

module {
  type JournalVector = Vec.Vector<(Time.Time, Principal, TokenHandler.LogEvent)>;

  public class TestJournal() {
    let journal : Vec.Vector<(Time.Time, Principal, TokenHandler.LogEvent)> = Vec.new();

    var counter_ = 0;
    public func counter() : Nat = counter_;

    var verbose = false;
    public func verboseOn() = verbose := true;
    public func verboseOff() = verbose := false;

    public func log(p : Principal, e : TokenHandler.LogEvent) {
      let event = (Time.now(), p, e);
      if (verbose) Debug.print("logging: " # debug_show event);
      Vec.add(journal, event);
    };

    public func hasEvents(events : [TokenHandler.LogEvent]) : Bool {
      let prevCounter = counter_; // previous size
      counter_ := Vec.size(journal);
      if (Vec.size(journal) != prevCounter + events.size()) return false;
      if (events.size() == 0) return true;
      for (i in Iter.range(prevCounter, prevCounter + events.size() - 1)) {
        let (_, _, event) = Vec.get(journal, i);
        if (event != events[i - prevCounter]) return false;
      };
      true;
    };

    public func size() : Nat = Vec.size(journal);

    public func debugShow(startFrom : Nat) : () {
      Debug.print(
        debug_show (
          Vec.toArray(journal)
          |> Array.slice(_, startFrom, _.size())
          |> Iter.toArray(_)
        )
      );
    };
  };
};