import 'dart:collection';

import 'package:piecemeal/piecemeal.dart';

import '../action/action.dart';
import '../hero/hero.dart';
import '../hero/hero_class.dart';
import '../hero/hero_save.dart';
import '../hero/lore.dart';
import '../hero/race.dart';
import '../hero/skill.dart';
import '../items/affix.dart';
import '../items/item_type.dart';
import '../items/shop.dart';
import '../monster/breed.dart';
import '../stage/stage.dart';
import 'actor.dart';
import 'element.dart';
import 'energy.dart';
import 'log.dart';

// 整个引擎的基类, 也是整个运行中的游戏本身
/// Root class for the game engine. All game state is contained within this.
class Game {
  // <?> 游戏本身的内容(是画面么)
  final Content content;

  final HeroSave _save;
  final log = Log();

  final _actions = Queue<Action>();
  final _reactions = <Action>[];

  /// The events that have occurred since the last call to [update()].
  final _events = <Event>[];

  /// The energy that tracks when the substances are ready to update.
  final _substanceEnergy = Energy();

  /// Substances work like a cellular automata. A normal cellular automata
  /// updates all cells simultaneously using double buffering. That wouldn't
  /// play nice with the game's action system, which likes to process each
  /// single action and its consequences to completion before moving to the
  /// next one.
  ///
  /// To handle that, we instead update substance cells one at a time. To avoid
  /// visible skew and artifacts from updating sequentially through the dungeon,
  /// we shuffle the cells and update them in random order. This is that order.
  final List<Vec> _substanceUpdateOrder = [];

  /// While the game is processing substance tiles, this is the index of the
  /// current tile's position in [_substanceUpdateOrder]. Otherwise, this is
  /// `null`.
  int? _substanceIndex;

  final int depth;

  Stage get stage => _stage;
  late Stage _stage;
  late Hero hero;

  Game(this.content, this._save, this.depth, {int? width, int? height}) {
    // TODO: Vary size?
    _stage = Stage(width ?? 80, height ?? 60, this);

    _substanceUpdateOrder.addAll(_stage.bounds.inflate(-1));
    rng.shuffle(_substanceUpdateOrder);
  }

  Iterable<String> generate() sync* {
    // TODO: Do something useful with depth.
    late Vec heroPos;
    yield* content.buildStage(_save.lore, _stage, depth, (pos) {
      heroPos = pos;
    });

    hero = Hero(this, heroPos, _save);
    _stage.addActor(hero);

    yield "Calculating visibility";
    _stage.refreshView();
  }

  // 游戏主循环在此
  GameResult update() {
    var madeProgress = false;

    // <?> 这个外层循环用来干什么
    while (true) {
      // Process any ongoing or pending actions.
      // 当前所有需要处理的actions从队列中诸葛取出
      while (_actions.isNotEmpty) {
        var action = _actions.first;

        // 执行对应的操作, 这个perform使得action与引擎解耦
        // result标志了这个action执行结果, 其中alternative代表执行失败但是有替代品
        var result = action.perform();

        // Cascade through the alternates until we hit bottom.
        // 用返回的替代action代替当前的action然后再执行一次
        while (result.alternative != null) {
          // 方法是将当前的action弹出然后将新的加入并调用
          _actions.removeFirst();
          action = result.alternative!;
          _actions.addFirst(action);

          result = action.perform();
        }

        // 执行所有的对应的reaction
        // reaction在立即形式的action执行后压入
        while (_reactions.isNotEmpty) {
          var reaction = _reactions.removeLast();
          var result = reaction.perform();

          // Cascade through the alternates until we hit bottom.
          while (result.alternative != null) {
            reaction = result.alternative!;
            result = reaction.perform();
          }

          assert(result.succeeded, "Reactions should never fail.");
        }

        // <?> action后刷新当前场景点亮的部分
        stage.refreshView();
        // 标记进行了实际的操作以供UI更新
        madeProgress = true;

        // 若action执行完成了, 则删掉这个action
        if (result.done) {
          _actions.removeFirst();

          if (result.succeeded && action.consumesEnergy) {
            action.actor!.finishTurn(action);
            stage.advanceActor();
          }

          // Refresh every time the hero takes a turn.
          // 当遍历到hero的时候需要将当前的结果提交给UI, 因此hero是最后一个处理的actor
          if (action.actor == hero) return makeResult(madeProgress);
        }

        // <?> _events是啥时候压入的
        if (_events.isNotEmpty) return makeResult(madeProgress);
      }

      // <?> 子实体是什么
      // If we are in the middle of updating substances, keep working through
      // them.
      if (_substanceIndex != null) {
        _updateSubstances();
      }

      // If we get here, all pending actions are done, so advance to the next
      // tick until an actor moves.
      // 处理完所有之前的action后, 开始更新actor的状态
      while (_actions.isEmpty) {
        var actor = stage.currentActor;

        // Input在等待的话不做UI处理除非有action被执行
        // If we are still waiting for input for the actor, just return (again).
        if (actor.energy.canTakeTurn && actor.needsInput) {
          return makeResult(madeProgress);
        }

        // 速度条的判断
        if (actor.energy.canTakeTurn || actor.energy.gain(actor.speed)) {
          // 当速度条和回合条都到了, 意味着轮到这个actor的回合了
          // If the actor can move now, but needs input from the user, just
          // return so we can wait for it.
          if (actor.needsInput) return makeResult(madeProgress);
          // 当有输入的时候, 这个actor的行为是为一个action, 从actor身上取出压入队列
          _actions.add(actor.getAction());
        } else {
          // 否则让速度条前进即可
          // This actor doesn't have enough energy yet, so move on to the next.
          stage.advanceActor();
        }

        // Each time we wrap around, process "idle" things that are ongoing and
        // speed independent.
        // <?> 是hero时, 设置实体能量积攒并刷新
        if (actor == hero) {
          if (_substanceEnergy.gain(Energy.normalSpeed)) {
            _substanceEnergy.spend();
            _substanceIndex = 0;
            _updateSubstances();
          }
//          trySpawnMonster();
        }
      }
    }
  }

  // action分为两类, 直接产生效果的action会有reaction
  void addAction(Action action) {
    if (action.isImmediate) {
      _reactions.add(action);
    } else {
      _actions.add(action);
    }
  }

  // 在这里压入action对应的事件
  // <?> 给其他action调用的?
  void addEvent(EventType type,
      {Actor? actor,
      Element? element,
      Object? other,
      Vec? pos,
      Direction? dir}) {
    _events.add(Event(type, actor, element ?? Element.none, pos, dir, other));
  }

  // 将当前的所有事件压入result并用于返回
  GameResult makeResult(bool madeProgress) {
    var result = GameResult(madeProgress);
    result.events.addAll(_events);
    _events.clear();
    return result;
  }

  //
  void _updateSubstances() {
    while (_substanceIndex! < _substanceUpdateOrder.length) {
      var pos = _substanceUpdateOrder[_substanceIndex!];
      var action = content.updateSubstance(stage, pos);
      _substanceIndex = _substanceIndex! + 1;

      if (action != null) {
        action.bindPassive(this, pos);
        _actions.add(action);
        return;
      }
    }

    // If we reach the end, we are done with them for now.
    _substanceIndex = null;
  }

// TODO: Decide if we want to keep this. Now that there is hunger forcing the
// player to explore, it doesn't seem strictly necessary.
  /// Over time, new monsters will appear in unexplored areas of the dungeon.
  /// This is to encourage players to not waste time: the more they linger, the
  /// more dangerous the remaining areas become.
//  void trySpawnMonster() {
//    if (!rng.oneIn(Option.spawnMonsterChance)) return;
//
//    // Try to place a new monster in unexplored areas.
//    Vec pos = rng.vecInRect(stage.bounds);
//
//    final tile = stage[pos];
//    if (tile.visible || tile.isExplored || !tile.isPassable) return;
//    if (stage.actorAt(pos) != null) return;
//
//    stage.spawnMonster(area.pickBreed(level), pos);
//  }
}

/// Defines the actual content for the game: the breeds, items, etc. that
/// define the play experience.
/// 引擎核心抽象类
abstract class Content {
  // TODO: Temp. Figure out where dungeon generator lives.
  // TODO: Using a callback to set the hero position is kind of hokey.
  Iterable<String> buildStage(
      Lore lore, Stage stage, int depth, Function(Vec) placeHero);

  Affix? findAffix(String name);

  Breed? tryFindBreed(String name);

  ItemType? tryFindItem(String name);

  Skill findSkill(String name);

  Iterable<Breed> get breeds;

  List<HeroClass> get classes;

  Iterable<Element> get elements;

  Iterable<ItemType> get items;

  List<Race> get races;

  Iterable<Skill> get skills;

  Map<String, Shop> get shops;

  HeroSave createHero(String name, [Race race, HeroClass heroClass]);

  Action? updateSubstance(Stage stage, Vec pos);
}

/// Each call to [Game.update()] will return a [GameResult] object that tells
/// the UI what happened during that update and what it needs to do.
// 这是Update的返回值, 用于告诉UI应该绘制什么新的信息
class GameResult {
  /// The "interesting" events that occurred in this update.
  // 告诉UI发生了些什么
  final events = <Event>[];

  // 等待Input的时候是完全静止的(不一定要学这个)
  /// Whether or not any game state has changed. If this is `false`, then no
  /// game processing has occurred (i.e. the game is stuck waiting for user
  /// input for the [Hero]).
  final bool madeProgress;

  /// Returns `true` if the game state has progressed to the point that a change
  /// should be shown to the user.
  bool get needsRefresh => madeProgress || events.isNotEmpty;

  // 虚构造
  GameResult(this.madeProgress);
}

/// Describes a single "interesting" thing that occurred during a call to
/// [Game.update()]. In general, events correspond to things that a UI is likely
/// to want to display visually in some form.
class Event {
  final EventType type;
  // TODO: Having these all be nullable leads to a lot of "!" in effects.
  // Consider a better way to model this.
  final Actor? actor;
  final Element element;
  final Object? other;
  final Vec? pos;
  final Direction? dir;

  Event(this.type, this.actor, this.element, this.pos, this.dir, this.other);
}

// TODO: Move to content.
/// A kind of [Event] that has occurred.
// action回引发各种类型的event
class EventType {
  static const pause = EventType("pause");

  /// One step of a bolt.
  static const bolt = EventType("bolt");

  /// The leading edge of a cone.
  static const cone = EventType("cone");

  /// A thrown item in flight.
  static const toss = EventType("toss");

  /// An [Actor] was hit.
  static const hit = EventType("hit");

  /// An [Actor] died.
  static const die = EventType("die");

  /// An [Actor] was healed.
  static const heal = EventType("heal");

  /// Something in the level was detected.
  static const detect = EventType("detect");

  /// An actor was perceived.
  static const perceive = EventType("perceive");

  /// A floor tile was magically explored.
  static const map = EventType("map");

  /// An [Actor] teleported.
  static const teleport = EventType("teleport");

  /// A new [Actor] was spawned by another.
  static const spawn = EventType("spawn");

  /// [Actor] has polymorphed into another breed.
  static const polymorph = EventType("polymorph");

  /// An [Actor] howls.
  static const howl = EventType("howl");

  /// An [Actor] wakes up.
  static const awaken = EventType("awaken");

  /// An [Actor] becomes afraid.
  static const frighten = EventType("frighten");

  /// An [Actor] was blown by wind.
  static const wind = EventType("wind");

  /// A club's bash attack moves an actor.
  static const knockBack = EventType("knockBack");

  /// An axe's slash attack hits a tile.
  static const slash = EventType("slash");

  /// A spear's stab attack hits a tile.
  static const stab = EventType("stab");

  /// The hero picks up gold worth [Event.other].
  static const gold = EventType("gold");

  static const openBarrel = EventType("openBarrel");

  final String _name;

  const EventType(this._name);

  String toString() => _name;
}
