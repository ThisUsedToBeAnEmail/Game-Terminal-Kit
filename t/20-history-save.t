#!perl
use 5.014;
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
use File::Spec;

use Game::Terminal::Kit::History;
use Game::Terminal::Kit::Save;

{
	package Moves;
	sub new { my ($class, @moves) = @_; return bless { moves => [@moves] }, $class }
	sub play { my ($self, $move) = @_; push @{ $self->{moves} }, $move; return $self }
	sub text { my ($self) = @_; return join ' ', @{ $self->{moves} } }
}

my $loaded = 0;

sub history {
	my (%option) = @_;
	return Game::Terminal::Kit::History->new(
		name => 'moves',
		save => sub { return $_[0]->text },
		load => sub { $loaded++; return Moves->new(split / /, $_[0]) },
		%option,
	);
}

sub moves { my ($game) = @_; return defined $game ? $game->text : undef }

# A game of five turns, two of them taken back.
sub played {
	my $history = history(@_);
	my $game = Moves->new;
	$history->start($game);
	$history->turn($game);
	$history->turn($game->play($_)) for qw/a b c d e/;
	$history->undo(2);
	return $history;
}

my $dir = tempdir(CLEANUP => 1);

subtest 'the steps of a history' => sub {
	plan tests => 4;
	my $history = played();
	is_deeply [$history->steps], ['', 'a', 'a b', 'a b c', 'a b c d', 'a b c d e'], 'every step, oldest first';
	is $history->at, 3, 'at is the current one';
	is scalar($history->steps), 6, 'in scalar context, steps is how many';
	is(($history->steps)[$history->at], $history->text, 'which is the text');
};

subtest 'a history saved' => sub {
	plan tests => 9;
	my $history = played(version => '1.2', settings => { level => 3 }, limit => 50);
	my $save = $history->saved;
	isa_ok $save, 'Game::Terminal::Kit::Save';
	is $save->name, 'moves', 'of the game it is a history of';
	is_deeply [$save->past, $save->current, $save->future],
		[['', 'a', 'a b'], 'a b c', ['a b c d', 'a b c d e']], 'every step, undo and redo both';
	is $save->limit, 50, 'and the limit';
	is $save->version, '1.2', 'and the version';
	is_deeply $save->settings, { level => 3 }, 'and the settings';
	$save->settings->{level} = 9;
	is $history->settings->{level}, 3, 'a copy of them';
	is $history->undo_count, 3, 'and the history is as it was';
	is $history->saved(file => 'there.save')->file, 'there.save', 'saved takes what to change';
};

subtest 'saved with the game as it is now' => sub {
	plan tests => 4;
	my $history = played();
	my $game = Moves->new(qw/a b c x/);
	my $save = $history->saved($game);
	is $save->current, 'a b c x', 'the game given is the current step';
	is_deeply $save->past, ['', 'a', 'a b', 'a b c'], 'after the one before it';
	is_deeply $save->future, [], 'a move made throws away what could be redone, as always';
	is $history->text, 'a b c x', 'and the history recorded it';
};

subtest 'a history needs a name to be saved' => sub {
	plan tests => 2;
	my $history = played(name => undef);
	ok !eval { $history->saved; 1 }, 'a history with no name';
	like $@, qr/needs the name of the game/, 'cannot be saved';
};

subtest 'a history resumed' => sub {
	plan tests => 16;
	my $save = played(limit => 50, settings => { level => 3 })->saved;
	$save->file('from.save');
	my $history = history();
	$loaded = 0;
	my $game = $history->resume($save);
	isa_ok $game, 'Moves', 'resume gives back the game';
	is moves($game), 'a b c', 'as it was saved';
	is $loaded, 1, 'built once';
	is $history->undo_count, 3, 'with the steps to undo';
	is $history->redo_count, 2, 'and to redo';
	is $history->limit, 50, 'the limit saved';
	is $history->store->history_limit, 50, 'and the store has it';
	is $history->file, 'from.save', 'and it knows the file';
	is_deeply $history->settings, { level => 3 }, 'and the settings';
	ok $history->begun, 'it has begun';

	is $history->start($game), $history, 'start with the game resumed';
	is $history->undo_count, 3, 'keeps what can be undone';
	$history->start($game);
	is $history->undo_count, 3, 'and so does a second start, as a game that starts twice makes';
	ok $history->resumed, 'which is still resumed';
	is $history->redo_count, 2, 'and redone';
	is moves($history->undo), 'a b', 'and an undo takes back a turn played before it was saved';
};

subtest 'turns after a resume are steps' => sub {
	plan tests => 7;
	my $history = history();
	my $game = $history->resume(played()->saved);
	$history->start($game);
	$history->turn($game);
	is $history->undo_count, 3, 'the first turn after a resume is no step: it is the game resumed';
	$history->turn($game->play('x'));
	is $history->undo_count, 4, 'a move after it is';
	is $history->redo_count, 0, 'and throws away what could have been redone';
	ok !$history->resumed, 'and the history is no longer as it was resumed';
	$history->start($game);
	is $history->undo_count, 0, 'so a start is a new start again';

	my $first = history();
	my $again = $first->resume(played()->saved);
	$first->turn($again->play('y'));
	is $first->undo_count, 4, 'a turn before start records too';
	is $first->text, 'a b c y', 'as a step';
};

subtest 'start with another game is a new game' => sub {
	plan tests => 3;
	my $history = history();
	$history->resume(played()->saved);
	$history->start(Moves->new(qw/z/));
	is $history->undo_count, 0, 'nothing to undo';
	is $history->redo_count, 0, 'nor to redo';
	ok !$history->begun, 'and the first turn begins it';
};

subtest 'what a resume refuses' => sub {
	plan tests => 5;
	my $history = history(name => 'chess');
	ok !eval { $history->resume(played()->saved); 1 }, 'a save of another game';
	like $@, qr/a history of chess, and that is a save of moves/, 'says whose';
	ok !eval { history()->resume({}); 1 }, 'something that is not a save';
	like $@, qr/resume needs a Game::Terminal::Kit::Save/, 'says what it needs';
	my $nothing = history(load => sub { return });
	ok !eval { $nothing->resume(played()->saved); 1 }, 'a load that gives back nothing';
};

subtest 'limits' => sub {
	plan tests => 5;
	my $history = history(limit => 7);
	$history->resume(Game::Terminal::Kit::Save->new(name => 'moves', limit => 2,
		past => ['', 'a', 'a b'], current => 'a b c'));
	is $history->limit, 2, 'the limit saved is the limit';
	is $history->undo_count, 2, 'and a past longer than it is cut to it';

	my $unsaid = played()->saved;
	$unsaid->limit(undef);
	$history = history(limit => 7);
	$history->resume($unsaid);
	is $history->limit, 7, 'a save that says no limit leaves the one the history has';

	my $none = played(limit => 0)->saved;
	$history = history();
	$history->resume($none);
	is $history->store->history_limit, undef, 'a limit of 0 keeps every step';
	is $history->undo_count, 3, 'and all of them are there';
};

subtest 'to a file, and carried on the next day' => sub {
	plan tests => 16;
	my $file = File::Spec->catfile($dir, 'moves.save');
	my $before = played(settings => { level => 2 });
	$before->saved->write_file($file);

	my $save = Game::Terminal::Kit::Save->read_file($file, game => 'moves');
	my $after = history();
	my $game = $after->resume($save);
	$after->start($game);
	is_deeply [$after->steps], [$before->steps], 'the steps are the steps that were saved';
	is $after->at, $before->at, 'at the same one';
	is $after->file, $file, 'and it knows its file';
	my $step = 0;
	for my $way (qw/undo undo undo undo redo redo redo redo redo redo/) {
		$step++;
		is moves($after->$way), moves($before->$way), "$way $step, as the history it was saved from";
	}
	is $after->text, $before->text, 'and the same where both end up';
	$after->saved->write_file($file);
	my $twice = Game::Terminal::Kit::Save->read_file($file);
	is_deeply [$twice->steps], [$before->steps], 'saved again, it is the same';
	is $twice->at, $before->at, 'at the same step';
};

subtest 'a step of a replay, carried on from' => sub {
	plan tests => 4;
	my $save = played()->saved;
	my $history = history();
	my $game = $history->resume($save->from_step(1));
	$history->start($game);
	is moves($game), 'a', 'the game at that step';
	is $history->undo_count, 1, 'with the one before it to undo';
	is $history->redo_count, 4, 'and every one after it to redo';
	is moves($history->redo(4)), 'a b c d e', 'up to the last';
};

subtest 'an undo or a redo after a resume ends it' => sub {
	plan tests => 4;
	my $history = history();
	my $game = $history->resume(played()->saved);
	$history->undo;
	ok !$history->resumed, 'an undo';
	my $back = $history->redo;
	$history->start($back);
	is $history->undo_count, 0, 'and a start after it is a new start';
	$history = history();
	$game = $history->resume(played()->saved);
	$history->redo;
	ok !$history->resumed, 'a redo';
	$history = history();
	$game = $history->resume(played()->saved);
	$history->record($game);
	ok $history->resumed, 'recording the game as it was resumed changes nothing';
};

done_testing;
