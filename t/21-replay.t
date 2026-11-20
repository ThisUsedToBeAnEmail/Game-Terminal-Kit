#!perl
use 5.014;
use strict;
use warnings;
use Test::More;

use Game::Terminal::Kit::Replay;
use Game::Terminal::Kit::Save;
use Game::Terminal::Kit::Log;
use Game::Terminal::Kit::Test::Screen qw/kit within/;

my $loaded = 0;

sub replay {
	my (%option) = @_;
	return Game::Terminal::Kit::Replay->new(
		steps => ['', 'a', 'a b', 'a b c'],
		load => sub { $loaded++; return [ split / /, $_[0] ] },
		draw => sub { my ($game) = @_; return ('board: ' . (@{$game} ? "@{$game}" : 'empty')) },
		%option,
	);
}

sub board { my ($replay) = @_; return ($replay->lines)[0] }

subtest 'what a replay needs' => sub {
	plan tests => 8;
	ok !eval { Game::Terminal::Kit::Replay->new(load => sub { 1 }, draw => sub { 1 }); 1 }, 'no steps';
	like $@, qr/steps, or a save, are needed/, 'says so';
	ok !eval { replay(steps => []); 1 }, 'no steps at all';
	ok !eval { replay(load => undef); 1 }, 'no load';
	like $@, qr/load and draw are both needed/, 'says so';
	ok !eval { replay(pace => 'soon'); 1 }, 'a pace that is not a number';
	ok replay(pace => 0.25), 'a fraction of a second will do';
	is replay(at => 9)->at, 0, 'a step that is not there starts at the first';
};

subtest 'from a save' => sub {
	plan tests => 4;
	my $save = Game::Terminal::Kit::Save->new(name => 'moves',
		past => ['', 'a'], current => 'a b', future => ['a b c']);
	my $replay = replay(steps => undef, save => $save);
	is_deeply $replay->steps, ['', 'a', 'a b', 'a b c'], 'every step of it';
	is $replay->mark, 2, 'marked where it was saved';
	is $replay->at, 0, 'from the first';
	is replay()->mark, 3, 'without a save the last step is the mark';
};

subtest 'what is drawn' => sub {
	plan tests => 8;
	$loaded = 0;
	my $replay = replay(mark => 2, head => ['moves, saved today']);
	my @lines = $replay->lines;
	is $lines[0], 'moves, saved today', 'the head first';
	is $lines[1], 'board: empty', 'then the board';
	like join("\n", @lines), qr/^step 1 of 4$/m, 'then which step it is';
	like join("\n", @lines), qr/space plays/, 'and the keys';
	$replay->go(2);
	like join("\n", $replay->lines), qr/^step 3 of 4, where it was saved$/m, 'the step it was saved at';
	$replay->go(3);
	like join("\n", $replay->lines), qr/^step 4 of 4, undone before it was saved$/m, 'and one undone before';
	$replay->go(0);
	$replay->lines for 1 .. 3;
	is $loaded, 3, 'a step is built once, however often it is drawn';
	is_deeply $replay->game(1), ['a'], 'game gives the game at a step';
};

subtest 'the keys' => sub {
	plan tests => 16;
	my $replay = replay();
	is_deeply [$replay->step('left')], ['none'], 'nothing before the first';
	is_deeply [$replay->step('right')], ['moved'], 'right is a step on';
	is board($replay), 'board: a', 'to the second';
	is_deeply [$replay->step('down')], ['moved'], 'down too';
	is_deeply [$replay->step('up')], ['moved'], 'up is a step back';
	is_deeply [$replay->step('end')], ['moved'], 'end';
	is board($replay), 'board: a b c', 'goes to the last';
	is_deeply [$replay->step('right')], ['none'], 'and there is nothing after it';
	is_deeply [$replay->step('home')], ['moved'], 'home';
	is $replay->at, 0, 'goes to the first';
	$replay->go(2);
	is_deeply [$replay->step('enter')], ['chosen', 2], 'enter chooses the step shown';
	is_deeply [$replay->step('q')], ['quit'], 'q stops';
	is_deeply [$replay->step('escape')], ['quit'], 'and escape';
	is_deeply [$replay->step(undef)], ['quit'], 'and the end of the keys';

	my $log = Game::Terminal::Kit::Log->new;
	$replay = replay(log => $log);
	is_deeply [$replay->step('x')], ['none'], 'a key that does nothing';
	like join("\n", $replay->lines), qr/That key does nothing here/, 'says so';
};

subtest 'playing' => sub {
	plan tests => 10;
	my $replay = replay();
	is_deeply [$replay->step(' ')], ['changed'], 'space plays';
	ok $replay->playing, 'and it is playing';
	like join("\n", $replay->lines), qr/^step 1 of 4, playing$/m, 'which the line says';
	$replay->tick;
	is $replay->at, 1, 'a tick is a step';
	$replay->tick for 1 .. 5;
	is $replay->at, 3, 'up to the last';
	ok !$replay->playing, 'where it stops';
	is_deeply [$replay->tick], ['none'], 'and a tick does nothing';
	$replay->step(' ');
	is $replay->at, 0, 'space at the last plays again from the first';
	$replay->step(' ');
	ok !$replay->playing, 'and space again stops it';
	$replay->tick;
	is $replay->at, 0, 'so a tick does nothing';
};

subtest 'a step that cannot be shown' => sub {
	plan tests => 4;
	my $replay = replay(draw => sub { die "no board for that\n" if @{ $_[0] } == 1; return 'fine' });
	is board($replay), 'fine', 'the steps that can be';
	$replay->go(1);
	is board($replay), 'step 2 cannot be shown: no board for that', 'one whose draw dies says so';
	my $empty = replay(load => sub { return });
	like board($empty), qr/step 1 cannot be shown: load gave nothing back for step 1/, 'and one load gives nothing for';
	$replay->go(2);
	is board($replay), 'fine', 'and the replay goes on';
};

subtest 'run, with keys' => sub {
	plan tests => 5;
	my ($keys, $screen, $text) = kit(keys => "\e[C\e[C\r");
	my @result = within(5, sub { replay()->run($keys, $screen) });
	is_deeply \@result, ['chosen', 2], 'right, right and enter choose the third step';
	like ${$text}, qr/board: a b/, 'which was drawn';

	($keys, $screen, $text) = kit(keys => ' ');
	my $replay = replay();
	@result = within(5, sub { $replay->run($keys, $screen) });
	is_deeply \@result, ['quit'], 'played to the end, then the keys ended';
	is $replay->at, 3, 'at the last step';
	like ${$text}, qr/board: a\b.*board: a b\b.*board: a b c/s, 'every step drawn on the way';
};

subtest 'play' => sub {
	plan tests => 9;
	my ($keys, $screen, $text) = kit(keys => "\e[Cq");
	my @result = within(5, sub { replay()->play($keys, $screen) });
	is_deeply \@result, ['quit'], 'on a terminal, the keys step it';
	ok !$keys->raw, 'and the keys are put back as they were';
	ok !$screen->cursor_hidden, 'and the cursor';

	($keys, $screen, $text) = kit(keys => "\e[Cq");
	$keys->enter_raw;
	within(5, sub { replay()->play($keys, $screen) });
	ok $keys->raw, 'keys that were raw are left raw';

	($keys, $screen, $text) = kit();
	my $replay = replay(mark => 2, head => ['a game of moves']);
	$replay->go(1);
	@result = within(5, sub { $replay->play($keys, $screen) });
	is_deeply \@result, ['quit'], 'off a terminal, it ends by itself';
	my @steps = ${$text} =~ m/^(step \d of 4.*)$/mg;
	is_deeply \@steps, ['step 1 of 4', 'step 2 of 4', 'step 3 of 4, where it was saved', 'step 4 of 4, undone before it was saved'],
		'with every step written out in turn';
	like ${$text}, qr/\Aa game of moves\n/, 'the head once, first';
	unlike ${$text}, qr/space plays/, 'and no keys that cannot be pressed';
	is $replay->at, 1, 'and the step shown is left as it was';
};

done_testing;
