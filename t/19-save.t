#!perl
use 5.014;
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
use File::Spec;

use Game::Terminal::Kit::Save;
use Game::Terminal::Kit::Test::Screen qw/kit within/;

my $dir = tempdir(CLEANUP => 1);
sub path { return File::Spec->catfile($dir, @_) }

sub save {
	my (%with) = @_;
	return Game::Terminal::Kit::Save->new(name => 'moves', current => 'e3 f4', %with);
}

sub dies_like {
	my ($body, $like, $name) = @_;
	my $lived = eval { $body->(); 1 };
	ok !$lived, $name;
	like $@, $like, "and says so: $name";
}

# Texts a step may be, every one of which must come back exactly.
my @awkward = (
	'', "\n", "\n\n", 'one line', "two\nlines", "trailing newline\n", "| a bar",
	"|", "end", "past", "current\nfuture", '  leading spaces', "trailing spaces  ",
	"a\rcarriage return", "caf\x{e9} \x{6b69}\x{263a}", "\x{1F600}", "tab\there",
	"setting level 9", "game-terminal-kit save 1",
);

subtest 'what a save needs' => sub {
	plan tests => 23;
	dies_like(sub { Game::Terminal::Kit::Save->new(current => 'x') }, qr/needs the name of the game/, 'no name');
	dies_like(sub { save(name => 'two words') }, qr/not a name a save can carry/, 'a name with a space');
	dies_like(sub { save(name => '') }, qr/not a name a save can carry/, 'an empty name');
	dies_like(sub { Game::Terminal::Kit::Save->new(name => 'moves') }, qr/needs the game as it is now/, 'no current step');
	dies_like(sub { save(current => [1]) }, qr/not text/, 'a current step that is not text');
	dies_like(sub { save(past => ['a', undef]) }, qr/a step of the past is not text/, 'an undef step');
	dies_like(sub { save(future => [{}]) }, qr/a step of the future is not text/, 'a reference for a step');
	dies_like(sub { save(settings => { level => "1\n2" }) }, qr/setting level is not one line/, 'a setting of two lines');
	dies_like(sub { save(settings => { 'two words' => 1 }) }, qr/not a name a setting can have/, 'a setting with a space in its name');
	dies_like(sub { save(limit => -1) }, qr/limit is not a whole number/, 'a negative limit');
	dies_like(sub { save(version => "0.1\n") }, qr/version is not one line/, 'a version of two lines');
	ok save(settings => { level => undef, seed => '' }), 'an undef setting, and an empty one, are allowed';
};

subtest 'the steps' => sub {
	plan tests => 13;
	my $save = save(past => [qw/a b/], current => 'c', future => [qw/d e f/]);
	is_deeply [$save->steps], [qw/a b c d e f/], 'every step, oldest first';
	is $save->at, 2, 'at is how many come before the current one';
	is $save->count, 6, 'and count how many there are';
	is scalar($save->steps), 6, 'as steps does in scalar context';

	my $later = $save->from_step(4);
	is_deeply [$later->past, $later->current, $later->future], [[qw/a b c d/], 'e', ['f']], 'from a later step';
	my $first = $save->from_step(0);
	is_deeply [$first->past, $first->current, $first->future], [[], 'a', [qw/b c d e f/]], 'from the first';
	my $last = $save->from_step(5);
	is_deeply [$last->past, $last->current, $last->future], [[qw/a b c d e/], 'f', []], 'from the last';
	is $later->name, 'moves', 'the name goes with it';

	my $set = save(settings => { level => 2 }, limit => 9, version => '1.0', file => 'x.save');
	my $copy = $set->from_step(0);
	is_deeply [$copy->settings, $copy->limit, $copy->version, $copy->file], [{ level => 2 }, 9, '1.0', 'x.save'],
		'and the settings, limit, version and file';
	$copy->settings->{level} = 5;
	is $set->settings->{level}, 2, 'the settings are a copy';
	dies_like(sub { $save->from_step(6) }, qr/there is no step 6/, 'a step past the end');
	ok !eval { $save->from_step(-1); 1 }, 'and one before the start';
};

subtest 'the text of a save' => sub {
	plan tests => 3;
	my $save = save(version => '0.05', saved_at => '2026-11-13T09:30:00Z', limit => 200,
		settings => { level => 3, colour => 'b', unset => undef },
		past => ['', "a\nb"], current => "c\n", future => ['d']);
	is $save->as_text, <<'TEXT', 'the lines, as the documentation gives them';
game-terminal-kit save 1
game moves
version 0.05
saved 2026-11-13T09:30:00Z
limit 200
setting colour b
setting level 3
past
past
| a
| b
current
| c
|
future
| d
end
TEXT
	my $bare = save()->as_text;
	is $bare, "game-terminal-kit save 1\ngame moves\ncurrent\n| e3 f4\nend\n", 'what is not said is left out';
	unlike $bare, qr/\| \n|[ \t]\n/, 'and no line ends in a space';
};

subtest 'every step comes back as it went' => sub {
	plan tests => 2 * @awkward + 3;
	for my $text (@awkward) {
		my $save = save(past => [$text, 'x'], current => $text, future => [$text]);
		my $back = Game::Terminal::Kit::Save->from_text($save->as_text);
		(my $name = $text) =~ s/([^ -~])/sprintf '\\x{%x}', ord $1/ge;
		is_deeply [$back->steps], [$save->steps], "'$name'";
		is $back->at, 2, "'$name' leaves the current step where it was";
	}
	my $all = save(past => [@awkward], current => 'now', future => [reverse @awkward],
		settings => { seed => "caf\x{e9} with spaces", level => '0' }, limit => 0);
	my $back = Game::Terminal::Kit::Save->from_text($all->as_text);
	is_deeply [$back->steps], [$all->steps], 'all of them at once';
	is_deeply $back->settings, $all->settings, 'and the settings, spaces and all';
	is $back->limit, 0, 'and a limit of 0';
};

subtest 'a text that is not a save' => sub {
	my $good = save(past => ['a'], future => ['b'])->as_text;
	my @cases = (
		['', qr/the text is not a saved game/, 'nothing'],
		["hello\n", qr/is not a saved game/, 'something else'],
		["game-terminal-kit save 2\ngame moves\ncurrent\nend\n", qr/format 2, newer than the format 1/, 'a newer format'],
		["game-terminal-kit save 1\ngame moves\ncurrent\n| x\n", qr/cut short/, 'no end'],
		["game-terminal-kit save 1\ncurrent\n| x\nend\n", qr/has no game line/, 'no game'],
		["game-terminal-kit save 1\ngame moves\nend\n", qr/has no current step/, 'no current step'],
		["game-terminal-kit save 1\ngame moves\ngame other\ncurrent\nend\n", qr/line 3: the game is there twice/, 'two games'],
		["game-terminal-kit save 1\ngame moves\ncurrent\ncurrent\nend\n", qr/line 4: a second current step/, 'two current steps'],
		["game-terminal-kit save 1\ngame moves\ncurrent\npast\nend\n", qr/line 4: a past step after the current one/, 'the past after the current'],
		["game-terminal-kit save 1\ngame moves\nfuture\ncurrent\nend\n", qr/line 3: a future step before the current one/, 'the future before the current'],
		["game-terminal-kit save 1\ngame moves\n| x\ncurrent\nend\n", qr/line 3: a line of a step before any step began/, 'a line before any step'],
		["game-terminal-kit save 1\ngame moves\ncurrent\nsetting a b\nend\n", qr/line 4: 'setting' after the steps began/, 'a setting among the steps'],
		["game-terminal-kit save 1\ngame moves\nWHAT is this\ncurrent\nend\n", qr/line 3: 'WHAT is this' is not a line/, 'a line that is no line'],
		["game-terminal-kit save 1\ngame\ncurrent\nend\n", qr/line 2: the game line has no value/, 'a game line with no game'],
		["game-terminal-kit save 1\ngame moves\nsetting level\ncurrent\nend\n", qr/a setting needs a name and a value/, 'a setting with no value'],
		["game-terminal-kit save 1\ngame moves\nsetting a 1\nsetting a 2\ncurrent\nend\n", qr/the setting a is there twice/, 'a setting twice'],
		["game-terminal-kit save 1\ngame moves\nlimit many\ncurrent\nend\n", qr/limit that is not a whole number/, 'a limit that is no number'],
		["game-terminal-kit save 1\ngame moves\ncurrent\nend\nmore\n", qr/line 5: there is more after the end/, 'something after the end'],
		["game-terminal-kit save 1\ngame two words\ncurrent\nend\n", qr/not a name a save can carry/, 'a name no save can carry'],
	);
	plan tests => 2 * @cases + 4;
	for my $case (@cases) {
		my ($text, $like, $name) = @{$case};
		dies_like(sub { Game::Terminal::Kit::Save->from_text($text) }, $like, $name);
	}
	dies_like(sub { Game::Terminal::Kit::Save->from_text($good, game => 'chess') },
		qr/is a saved game of moves, not of chess/, 'a save of another game');
	dies_like(sub { Game::Terminal::Kit::Save->from_text(undef) }, qr/is not text/, 'undef');
};

subtest 'a text cut short anywhere is refused' => sub {
	my $text = save(past => ["a\nb", 'c'], current => "d\ne", future => ['f'],
		settings => { level => 1 })->as_text;
	my @lines = split /(?<=\n)/, $text;
	plan tests => scalar @lines;
	for my $keep (0 .. $#lines - 1) {
		my $cut = join '', @lines[0 .. $keep];
		ok !eval { Game::Terminal::Kit::Save->from_text($cut); 1 }, "cut after line " . ($keep + 1);
	}
	ok eval { Game::Terminal::Kit::Save->from_text($text); 1 }, 'and the whole of it is read';
};

subtest 'what a reader lets pass' => sub {
	plan tests => 5;
	my $save = save(past => ["a\nb"], current => 'c', settings => { level => 1 });
	(my $crlf = $save->as_text) =~ s/\n/\r\n/g;
	is_deeply [Game::Terminal::Kit::Save->from_text($crlf)->steps], [$save->steps], 'a file given CRLF line ends';
	my $later = "game-terminal-kit save 1\ngame moves\ncolour blue\ncurrent\n| x\nend\n";
	is(Game::Terminal::Kit::Save->from_text($later)->current, 'x', 'a header line a later version might add');
	my $blank = "game-terminal-kit save 1\n\ngame moves\n\ncurrent\n| x\nend\n\n\n";
	is(Game::Terminal::Kit::Save->from_text($blank)->current, 'x', 'blank lines in the header and after the end');
	my $no_newline = "game-terminal-kit save 1\ngame moves\ncurrent\n| x\nend";
	is(Game::Terminal::Kit::Save->from_text($no_newline)->current, 'x', 'no newline after end');
	my $bar = "game-terminal-kit save 1\ngame moves\ncurrent\n|\n|x\nend\n";
	is(Game::Terminal::Kit::Save->from_text($bar)->current, "\nx", 'a bar alone is an empty line, and the space after one is optional');
};

subtest 'to a file and back' => sub {
	plan tests => 18;
	my $save = save(past => [@awkward], current => "caf\x{e9}", future => ['z'], settings => { level => 4 });
	my $file = path('one.save');
	is $save->write_file($file), $file, 'write_file gives back the path';
	ok -f $file, 'and the file is there';
	is $save->file, $file, 'and the save knows it';
	like $save->saved_at, qr/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, 'and when, in UTC';
	open my $fh, '<:raw', $file or die $!;
	my $bytes = do { local $/; <$fh> };
	close $fh;
	my $expect = $save->as_text;
	utf8::encode($expect);
	is $bytes, $expect, 'what is in the file is as_text, in UTF-8';
	my @left = glob(path('*.tmp'));
	is scalar @left, 0, 'and nothing is left beside it';

	my $back = Game::Terminal::Kit::Save->read_file($file, game => 'moves');
	is_deeply [$back->steps], [$save->steps], 'read back, every step is the same';
	is $back->file, $file, 'it knows where it came from';
	is $back->saved_at, $save->saved_at, 'and when it was saved';
	is_deeply $back->settings, { level => 4 }, 'and the settings';

	dies_like(sub { Game::Terminal::Kit::Save->read_file($file, game => 'chess') },
		qr/\Q$file\E is a saved game of moves, not of chess/, 'a save of another game, named with its file');
	dies_like(sub { Game::Terminal::Kit::Save->read_file(path('none.save')) }, qr/there is no file/, 'no file');
	dies_like(sub { Game::Terminal::Kit::Save->read_file($dir) }, qr/is a directory/, 'a directory');
	my $latin = path('latin.save');
	open my $out, '>:raw', $latin or die $!;
	print {$out} "game-terminal-kit save 1\ngame moves\ncurrent\n| caf\xe9\nend\n";
	close $out;
	dies_like(sub { Game::Terminal::Kit::Save->read_file($latin) }, qr/is not a saved game/, 'text that is not UTF-8');
};

subtest 'a write that fails leaves what was there' => sub {
	plan tests => 12;
	my $file = path('kept.save');
	save(current => 'first')->write_file($file);
	my $before = Game::Terminal::Kit::Save->read_file($file)->current;

	my $broken = save(current => 'second');
	$broken->current([1]);
	ok !eval { $broken->write_file($file); 1 }, 'a save that cannot be written as text';
	is(Game::Terminal::Kit::Save->read_file($file)->current, $before, 'leaves the file as it was');
	is $broken->saved_at, undef, 'and the save as it was';

	my $nowhere = path('no', 'such', 'dir', 'x.save');
	dies_like(sub { save()->write_file($nowhere) }, qr/cannot write \Q$nowhere\E/, 'a directory that is not there');

	my $taken = path('a-directory');
	mkdir $taken or die $!;
	dies_like(sub { save()->write_file($taken) }, qr/cannot write \Q$taken\E/, 'a path that is a directory');
	ok -d $taken, 'which is still a directory';
	is scalar(() = glob(path('*.tmp'))), 0, 'and nothing is left beside it';

	dies_like(sub { save()->write_file('') }, qr/needs a file/, 'no path');
	save(current => 'third')->write_file($file);
	is(Game::Terminal::Kit::Save->read_file($file)->current, 'third', 'a write that works replaces the file');
};

subtest 'the command line' => sub {
	plan tests => 13;
	is_deeply [Game::Terminal::Kit::Save::flags()], [qw/save=s resume=s replay=s/], 'the three options';
	is Game::Terminal::Kit::Save::check_flags({}), undef, 'none of them';
	is Game::Terminal::Kit::Save::check_flags({ save => 'a', resume => 'a' }), undef, 'save and resume';
	is Game::Terminal::Kit::Save::check_flags({ replay => 'a' }), undef, 'replay';
	like Game::Terminal::Kit::Save::check_flags({ resume => 'a', replay => 'b' }), qr/give one of them/, 'resume and replay';
	like Game::Terminal::Kit::Save::check_flags({ save => 'a', replay => 'b' }), qr/--replay writes nothing/, 'save and replay';
	like Game::Terminal::Kit::Save::check_flags({ resume => '' }), qr/--resume needs the name of a file/, 'an empty file';
	like Game::Terminal::Kit::Save::usage(), qr/--save FILE.*--resume FILE.*--replay FILE/s, 'the usage names all three';
	is Game::Terminal::Kit::Save::default_file('reversi'), 'reversi.save', 'the default file';
	is_deeply Game::Terminal::Kit::Save::game_keys(), { S => 'save' }, 'S saves';
	is_deeply [Game::Terminal::Kit::Save::command('save')], [1, undef], 'a typed save';
	is_deeply [Game::Terminal::Kit::Save::command('  SAVE  my game.save ')], [1, 'my game.save'], 'and one naming a file';
	is_deeply [Game::Terminal::Kit::Save::command('saves'), Game::Terminal::Kit::Save::command('e2e4'),
		Game::Terminal::Kit::Save::command(undef)], [], 'and lines that are not';
};

subtest 'asking where' => sub {
	plan tests => 7;
	my ($keys, $screen, $text) = kit(keys => "\r");
	$keys->enter_raw;
	is within(5, sub { Game::Terminal::Kit::Save::ask_file($keys, $screen, default => 'reversi.save') }),
		'reversi.save', 'enter takes the default';
	like ${$text}, qr/save to: reversi\.save/, 'which was shown already typed';

	($keys, $screen) = kit(keys => "\x7f" x 12 . "mine.save\r");
	$keys->enter_raw;
	is within(5, sub { Game::Terminal::Kit::Save::ask_file($keys, $screen, default => 'reversi.save') }),
		'mine.save', 'it can be rubbed out and another typed';

	($keys, $screen) = kit(keys => "\e");
	$keys->enter_raw;
	is within(5, sub { Game::Terminal::Kit::Save::ask_file($keys, $screen, default => 'x') }), undef, 'escape backs out';

	($keys, $screen) = kit(typed => ['']);
	is Game::Terminal::Kit::Save::ask_file($keys, $screen, default => 'go.save'), 'go.save', 'typed, an empty line is the default';
	($keys, $screen) = kit(typed => ['there.save']);
	is Game::Terminal::Kit::Save::ask_file($keys, $screen, default => 'go.save'), 'there.save', 'or a file is typed';
	($keys, $screen) = kit(typed => []);
	is Game::Terminal::Kit::Save::ask_file($keys, $screen, default => 'go.save'), undef, 'and the end of the input backs out';
};

subtest 'read_game, saves_in and why' => sub {
	plan tests => 13;
	my $saves = tempdir(CLEANUP => 1);
	my $at = sub { File::Spec->catfile($saves, @_) };
	my $older = save(name => 'reversi', current => 'old');
	$older->write_file($at->('older.save'));
	$older->saved_at('2026-01-01T00:00:00Z');
	open my $fh, '>', $at->('older.save') or die $!;
	print {$fh} $older->as_text;
	close $fh;
	save(name => 'reversi', current => 'new')->write_file($at->('newer.save'));
	save(name => 'chess', current => 'c')->write_file($at->('chess.save'));
	open $fh, '>', $at->('junk.save') or die $!;
	print {$fh} "not a save\n";
	close $fh;
	open $fh, '>', $at->('notes.txt') or die $!;
	print {$fh} "not even named like one\n";
	close $fh;
	mkdir $at->('folder.save');

	my @found = Game::Terminal::Kit::Save::saves_in($saves, game => 'reversi');
	is_deeply [map { $_->current } @found], [qw/new old/], 'the saves of one game, the last saved first';
	is $found[0]->file, $at->('newer.save'), 'each knowing its file';
	my @all = Game::Terminal::Kit::Save::saves_in($saves);
	is scalar @all, 3, 'every save, without a game: not the junk, the text or the directory';
	is_deeply [Game::Terminal::Kit::Save::saves_in($at->('nowhere'))], [], 'none in a directory that is not there';

	my ($read, $why) = Game::Terminal::Kit::Save->read_game($at->('newer.save'), 'reversi');
	is $read->current, 'new', 'read_game reads one';
	is $why, undef, 'with nothing to say';
	($read, $why) = Game::Terminal::Kit::Save->read_game($at->('chess.save'), 'reversi');
	is $read, undef, 'not a save of that game';
	is $why, $at->('chess.save') . ' is a saved game of chess, not of reversi', 'says so, as a person reads it';
	(undef, $why) = Game::Terminal::Kit::Save->read_game($at->('none.save'), 'reversi');
	is $why, 'there is no file ' . $at->('none.save'), 'and a file that is not there';

	is Game::Terminal::Kit::Save::why("Game::Reversi::Terminal: the level is 9.\n"), 'the level is 9', 'why: no module, no full stop';
	is Game::Terminal::Kit::Save::why("it broke at /x/y.pm line 12.\n"), 'it broke', 'no line';
	is Game::Terminal::Kit::Save::why('plain words'), 'plain words', 'and plain words are left';
	like Game::Terminal::Kit::Save::why(''), qr/said nothing/, 'and nothing at all is still a sentence';
};

done_testing;
