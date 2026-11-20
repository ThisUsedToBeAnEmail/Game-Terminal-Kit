package Game::Terminal::Kit::Save;

use 5.014;
use strict;
use warnings;

use Carp ();
use File::Spec ();
use Object::Proto::Sugar -types;
use Game::Terminal::Kit::Line;

our $VERSION = '0.06';

our $FORMAT = 1;
my $MAGIC = 'game-terminal-kit save';
my %BLOCK = map { $_ => 1 } qw/past current future/;
my $NAME = qr/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/;

has [qw/name version saved_at file/] => (
	is => 'rw',
	isa => Str
);

has current => (
	is => 'rw',
	isa => Str
);

has [qw/past future/] => (
	is => 'rw',
	isa => ArrayRef
);

has settings => (
	is => 'rw',
	isa => HashRef
);

has limit => (
	is => 'rw',
	isa => Int
);

sub BUILD {
	my ($self) = @_;
	$self->past([]) unless $self->past;
	$self->future([]) unless $self->future;
	$self->settings({}) unless $self->settings;
	$self->check;
	return $self;
}

sub _fail {
	my ($why) = @_;
	Carp::croak("Game::Terminal::Kit::Save: $why");
}

sub check {
	my ($self) = @_;
	my $name = $self->name;
	_fail('a save needs the name of the game') unless defined $name && !ref $name;
	_fail("'$name' is not a name a save can carry") unless $name =~ $NAME;
	for my $field (qw/version saved_at/) {
		my $value = $self->$field;
		_fail("the $field is not one line of text")
			if defined $value && (ref $value || $value =~ m/[\r\n]/ || $value !~ m/\S/);
	}
	_fail('the limit is not a whole number') if defined $self->limit && $self->limit !~ m/\A\d+\z/;
	_fail('a save needs the game as it is now') unless defined $self->current;
	for my $which (qw/past future/) {
		my $steps = $self->$which;
		_fail("the $which is not a list of steps") unless ref $steps eq 'ARRAY';
		_fail("a step of the $which is not text") if grep { !defined || ref } @{$steps};
	}
	_fail('the game as it is now is not text') if ref $self->current;
	my $settings = $self->settings;
	_fail('the settings are not a hash') unless ref $settings eq 'HASH';
	for my $key (sort keys %{$settings}) {
		_fail("'$key' is not a name a setting can have") unless $key =~ $NAME;
		my $value = $settings->{$key};
		_fail("the setting $key is not one line of text")
			if defined $value && (ref $value || $value =~ m/[\r\n]/);
	}
	return $self;
}

sub steps {
	my ($self) = @_;
	return $self->count unless wantarray;
	return (@{ $self->past }, $self->current, @{ $self->future });
}

sub at {
	my ($self) = @_;
	return scalar @{ $self->past };
}

sub count {
	my ($self) = @_;
	return @{ $self->past } + 1 + @{ $self->future };
}

sub from_step {
	my ($self, $index) = @_;
	my @steps = $self->steps;
	_fail("there is no step $index") unless defined $index && $index =~ m/\A\d+\z/ && $index < @steps;
	return ref($self)->new(
		(map { defined $self->$_ ? ($_ => $self->$_) : () } qw/name version saved_at file limit/),
		settings => { %{ $self->settings } },
		past => [ @steps[0 .. $index - 1] ],
		current => $steps[$index],
		future => [ @steps[$index + 1 .. $#steps] ],
	);
}

sub _now {
	my @t = gmtime;
	return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0];
}

sub _block {
	my ($keyword, $text) = @_;
	return ($keyword, map { length $_ ? "| $_" : '|' } split /\n/, $text, -1);
}

sub as_text {
	my ($self) = @_;
	$self->check;
	my $settings = $self->settings;
	my @lines = (
		"$MAGIC $FORMAT",
		'game ' . $self->name,
		(defined $self->version ? 'version ' . $self->version : ()),
		(defined $self->saved_at ? 'saved ' . $self->saved_at : ()),
		(defined $self->limit ? 'limit ' . $self->limit : ()),
		(map { "setting $_ $settings->{$_}" } grep { defined $settings->{$_} } sort keys %{$settings}),
		(map { _block(past => $_) } @{ $self->past }),
		_block(current => $self->current),
		(map { _block(future => $_) } @{ $self->future }),
		'end',
	);
	return join '', map { "$_\n" } @lines;
}

sub from_text {
	my ($class, $text, %expect) = @_;
	my $source = defined $expect{source} ? $expect{source} : 'the text';
	my $refuse = sub {
		my ($number, $why) = @_;
		_fail("$source " . (defined $number ? "line $number: " : '') . $why);
	};
	$refuse->(undef, 'is not text') unless defined $text && !ref $text;

	my @lines = split /\n/, $text, -1;
	pop @lines if @lines && $lines[-1] eq '';
	my $crlf = @lines && $lines[0] =~ m/\r\z/;
	s/\r\z// for $crlf ? @lines : ();

	my $first = @lines ? $lines[0] : '';
	$refuse->(undef, 'is not a saved game') unless $first =~ m/\A\Q$MAGIC\E (\d+)\z/;
	$refuse->(undef, "was saved in format $1, newer than the format $FORMAT this Game::Terminal::Kit reads")
		if $1 > $FORMAT;

	my (%head, %settings, @past, @future, $current, $in, $ended);
	my $number = 1;
	for my $line (@lines[1 .. $#lines]) {
		$number++;
		if ($ended) {
			$refuse->($number, 'there is more after the end') if $line =~ m/\S/;
			next;
		}
		if ($line =~ m/\A\| ?(.*)\z/s) {
			$refuse->($number, 'a line of a step before any step began') unless $in;
			push @{ $in->{lines} }, defined $1 ? $1 : '';
			next;
		}
		if ($BLOCK{$line}) {
			$refuse->($number, 'a second current step') if $line eq 'current' && defined $current;
			$refuse->($number, 'a past step after the current one') if $line eq 'past' && defined $current;
			$refuse->($number, 'a future step before the current one') if $line eq 'future' && !defined $current;
			my $step = { lines => [] };
			if ($line eq 'past') { push @past, $step }
			elsif ($line eq 'future') { push @future, $step }
			else { $current = $step }
			$in = $step;
			next;
		}
		if ($line eq 'end') {
			$ended = 1;
			next;
		}
		next if !$in && $line !~ m/\S/;
		my ($key, $value) = $line =~ m/\A([a-z]+)(?: (.*))?\z/s
			or $refuse->($number, "'$line' is not a line a saved game has");
		$refuse->($number, "'$key' after the steps began") if $in;
		$refuse->($number, "the $key line has no value")
			if !defined $value && $key =~ m/\A(?:game|version|saved|limit|setting)\z/;
		if ($key eq 'setting') {
			my ($name, $setting) = defined $value ? $value =~ m/\A(\S+) (.*)\z/s : ()
				or $refuse->($number, 'a setting needs a name and a value');
			$refuse->($number, "the setting $name is there twice") if exists $settings{$name};
			$settings{$name} = $setting;
			next;
		}
		$refuse->($number, "the $key is there twice") if exists $head{$key};
		$head{$key} = $value;
	}
	$refuse->(undef, 'ends before its last line, and may have been cut short') unless $ended;
	$refuse->(undef, 'has no game line') unless defined $head{game};
	$refuse->(undef, 'has no current step') unless defined $current;
	$refuse->(undef, "is a saved game of $head{game}, not of $expect{game}")
		if defined $expect{game} && $head{game} ne $expect{game};
	$refuse->(undef, 'has a limit that is not a whole number')
		if defined $head{limit} && $head{limit} !~ m/\A\d+\z/;

	my $text_of = sub { join "\n", @{ $_[0]{lines} } };
	my $save = eval {
		$class->new(
			name => $head{game},
			(defined $head{version} ? (version => $head{version}) : ()),
			(defined $head{saved} ? (saved_at => $head{saved}) : ()),
			(defined $head{limit} ? (limit => $head{limit} + 0) : ()),
			settings => \%settings,
			past => [ map { $text_of->($_) } @past ],
			current => $text_of->($current),
			future => [ map { $text_of->($_) } @future ],
		);
	};
	unless ($save) {
		(my $why = $@) =~ s/\AGame::Terminal::Kit::Save: //;
		$why =~ s/ at \S+ line \d+\.?\n?\z//;
		$refuse->(undef, $why);
	}
	return $save;
}

sub write_file {
	my ($self, $path) = @_;
	_fail('write_file needs a file to write') unless defined $path && length $path;
	my $keep = $self->saved_at;
	$self->saved_at(_now());
	my $text = eval { $self->as_text };
	unless (defined $text) {
		my $why = $@;
		$self->saved_at($keep);
		die $why;
	}
	my $temporary = "$path.$$.tmp";
	my $fh;
	unless (open $fh, '>:raw:encoding(UTF-8)', $temporary) {
		my $why = $!;
		$self->saved_at($keep);
		_fail("cannot write $path: $why");
	}
	my $wrote = print {$fh} $text;
	my $why = $!;
	$wrote = close($fh) && $wrote;
	$why = $! unless $wrote || $why;
	$wrote &&= rename $temporary, $path;
	unless ($wrote) {
		$why = $! if !$why;
		unlink $temporary;
		$self->saved_at($keep);
		_fail("cannot write $path: $why");
	}
	$self->file($path);
	return $path;
}

sub read_file {
	my ($class, $path, %expect) = @_;
	_fail('read_file needs a file to read') unless defined $path && length $path;
	_fail("there is no file $path") unless -e $path;
	_fail("$path is a directory, not a saved game") if -d $path;
	open my $fh, '<:raw', $path or _fail("cannot read $path: $!");
	my $bytes = do { local $/; readline $fh };
	close $fh;
	$bytes = '' unless defined $bytes;
	_fail("$path is not a saved game") unless utf8::decode($bytes);
	my $save = $class->from_text($bytes, %expect, source => $path);
	$save->file($path);
	return $save;
}

sub read_game {
	my ($class, $path, $name) = @_;
	my $save = eval { $class->read_file($path, (defined $name ? (game => $name) : ())) };
	return $save if $save;
	return (undef, why($@));
}

sub saves_in {
	my ($dir, %option) = @_;
	$dir = '.' unless defined $dir && length $dir;
	opendir my $listing, $dir or return ();
	my @names = sort grep { m/\.save\z/ && !m/\A\./ } readdir $listing;
	closedir $listing;
	my @found;
	for my $name (@names) {
		my $path = $dir eq '.' ? $name : File::Spec->catfile($dir, $name);
		next unless -f $path && -s _ <= 16 * 1024 * 1024;
		my ($save) = __PACKAGE__->read_game($path, $option{game});
		push @found, $save if $save;
	}
	return sort {
		(defined $b->saved_at ? $b->saved_at : '') cmp (defined $a->saved_at ? $a->saved_at : '')
			|| $a->file cmp $b->file
	} @found;
}

sub why {
	my ($error) = @_;
	$error = 'it failed, and said nothing of why' unless defined $error && length $error;
	$error =~ s/ at \S+ line \d+\.?\s*\z//;
	$error =~ s/\A(?:[A-Z]\w*(?:::\w+)*): //;
	$error =~ s/\.?\s*\z//;
	return $error;
}

sub default_file {
	my ($name) = @_;
	return (defined $name && length $name ? $name : 'game') . '.save';
}

sub flags {
	return ('save=s', 'resume=s', 'replay=s');
}

sub check_flags {
	my ($given) = @_;
	my @set = grep { defined $given->{$_} } qw/save resume replay/;
	for my $flag (@set) {
		return "--$flag needs the name of a file" unless length $given->{$flag};
	}
	return '--resume and --replay each start from a saved game: give one of them'
		if defined $given->{resume} && defined $given->{replay};
	return '--save is where a game is written, and --replay writes nothing'
		if defined $given->{save} && defined $given->{replay};
	return undef;
}

sub usage {
	return <<'USAGE';
  --save FILE     where S, or "save", writes the game. Default: the file
                  the game was resumed from, or NAME.save.
  --resume FILE   carry on a game saved to FILE, undo and redo and all.
  --replay FILE   watch a game saved to FILE, a step at a time.
USAGE
}

sub command {
	my ($line) = @_;
	return () unless defined $line;
	return () unless $line =~ m/\A\s*save(?:\s+(.*?))?\s*\z/i;
	return (1, defined $1 && length $1 ? $1 : undef);
}

sub game_keys {
	return { S => 'save' };
}

sub ask_file {
	my ($keys, $screen, %option) = @_;
	my $default = defined $option{default} ? $option{default} : '';
	my $prompt = defined $option{prompt} ? $option{prompt} : 'save to: ';
	unless ($keys->raw) {
		my $line = $keys->read_line("$prompt\[$default] ", $screen->out);
		return undef unless defined $line;
		return length $line ? $line : (length $default ? $default : undef);
	}
	my $line = Game::Terminal::Kit::Line->new(
		prompt => $prompt,
		text => $default,
		head => [ @{ $option{head} || [] } ],
		screen => $screen,
	);
	my ($event, $value) = $line->run($keys, $screen);
	return undef unless $event eq 'chosen';
	$value =~ s/^\s+|\s+$//g;
	return length $value ? $value : undef;
}

1;

__END__

=head1 NAME

Game::Terminal::Kit::Save - a game written to a file, to carry on or watch later

=head1 VERSION

Version 0.06

=head1 SYNOPSIS

    use Game::Terminal::Kit::Save;

    # in the game: S, or "save", writes it
    my $file = $history->saved->write_file($path);

    # the next day: --resume carries on
    my $save = Game::Terminal::Kit::Save->read_file($path, game => 'reversi');
    my $game = $history->resume($save);

    # or --replay watches it
    my $replay = Game::Terminal::Kit::Replay->new(
        save => $save,
        load => sub { Game::Reversi->from_text($_[0]) },
        draw => sub { my ($game) = @_; board_lines($game) },
    );
    $replay->play($keys, $screen);

=head1 DESCRIPTION

A saved game: which game it is, the settings it was played with, and every
step of its L<Game::Terminal::Kit::History>: the ones that could be undone,
the game as it was, and the ones that could be redone. A game carried on
from a save can take back a move made before it was saved.

A step is the game as its C<save> wrote it, a string. The kit does not know
what the string says; the game that wrote it reads it back.

Nothing here reads or writes a file but L</read_file> and L</write_file>.
Everything else, L</as_text> and L</from_text> included, works on strings.

=head2 The file

Plain text, in UTF-8, one thing to a line, so that a person can read one
and a diff of two says something:

    game-terminal-kit save 1
    game reversi
    version 0.05
    saved 2026-11-13T09:30:00Z
    limit 200
    setting colour b
    setting level 3
    past
    | variant othello
    | seed 7265766572736921
    current
    | variant othello
    | seed 7265766572736921
    | f5 d6
    future
    | variant othello
    | seed 7265766572736921
    | f5 d6 c3
    end

The first line says what the file is and the format it is in. Then come the
game's name, the version of the game that saved it, when, the history's
limit, and the settings, one to a line. Then the steps, oldest first: each
is a line saying which kind of step it is, then the lines of its text, each
after a C<|> and a space. The reader takes the space as optional, for a file
someone has edited by hand. The file ends with C<end>, so one that was cut
short is not taken for a shorter game.

A line the reader does not know, before the steps, is not an error, so that
a later version can add one; a format number it does not know is.

Writing goes to a new file beside the one named, which then takes its
place, so a save that fails part way leaves the old file as it was.

=head1 ATTRIBUTES

=head2 name

The game's name, such as C<reversi>: the word the L<Game::Terminal> roster
knows it by. Needed. Letters, digits and C<_ . ->.

=head2 version

The version of the game that saved it. Not checked: it is for a person
wondering why an old save no longer loads.

=head2 settings

A hash of the settings the game was played with, such as the level and the
side the person plays, by the names the game's command line gives them. A
setting is one line of text; one that is undef is left out.

=head2 past

=head2 current

=head2 future

The steps: the ones undo could reach, oldest first; the game as it was; and
the ones redo could reach, the next first. Each a string.

=head2 limit

The history's limit, as L<Game::Terminal::Kit::History/limit> has it, or
undef when the save does not say.

=head2 saved_at

When it was written, in UTC, set by L</write_file>.

=head2 file

The file it was read from or last written to.

=head1 METHODS

=head2 new

    my $save = Game::Terminal::Kit::Save->new(name => 'reversi', current => $text, ...);

Dies when something is missing or not what it should be, as L</check> says.
A game does not usually make one: L<Game::Terminal::Kit::History/saved> does.

=head2 check

Dies, naming the problem, unless the save can be written. Returns the save.

=head2 steps

Every step, oldest first: the past, the current, the future. In scalar
context, how many, as L</count>.

=head2 at

Where the current step is among L</steps>: how many steps come before it.

=head2 count

How many steps there are.

=head2 from_step

    my $later = $save->from_step(4);

A new save whose current step is the fifth of L</steps>, with the ones
before it to undo and the ones after it to redo. What a replay hands back
when the person chooses to play on from the step shown.

=head2 as_text

The save as the file holds it.

=head2 from_text

    my $save = Game::Terminal::Kit::Save->from_text($text, game => 'reversi');

A save read back from what L</as_text> wrote. With C<game>, dies unless it
is a save of that game. Dies, naming the line, when the text is not a save.
C<source> names where the text came from, for the message.

=head2 write_file

    my $path = $save->write_file($path);

Writes the save to a file, and returns the path. Dies, saying why, when it
cannot; the file that was there is then untouched.

=head2 read_file

    my $save = Game::Terminal::Kit::Save->read_file($path, game => 'reversi');

A save read from a file. As L</from_text>, and dies when the file is not
there, cannot be read, or is not text in UTF-8.

=head1 FUNCTIONS

For a game's command line and keys. None is exported.

=head2 flags

    Getopt::Long::GetOptionsFromArray(\@argv, \%opt, ..., Game::Terminal::Kit::Save::flags());

C<save=s>, C<resume=s> and C<replay=s>: the three options every game takes.

=head2 check_flags

    if (my $why = Game::Terminal::Kit::Save::check_flags(\%opt)) { ... }

What is wrong with the three as given, as a sentence, or undef: each needs a
file, C<--resume> and C<--replay> are two ways to start from a save and one
is all that can be used, and C<--replay> writes nothing for C<--save> to
name.

=head2 usage

The lines a game's C<--help> gives the three.

=head2 read_game

    my ($save, $why) = Game::Terminal::Kit::Save->read_game($path, 'reversi');

L</read_file> for a game's command line: the save, or undef and a sentence
saying why not, as L</why> makes it. A save of another game is a why.

=head2 saves_in

    my @saves = Game::Terminal::Kit::Save::saves_in('.', game => 'reversi');

The saves in a directory, the current one unless one is given: every file
whose name ends in F<.save> that reads as a save, of the game named when
C<game> is given, the one saved last first. A file that does not read is
left out, and so is one over 16 megabytes. For a menu offering a saved game
to carry on or watch.

=head2 why

    my $sentence = Game::Terminal::Kit::Save::why($@);

An error as a person should read it: without the C<at FILE line N> perl adds,
without the name of the module that said it at the front, and without its
full stop, so that it can go into a sentence.

=head2 default_file

    my $path = Game::Terminal::Kit::Save::default_file('reversi');   # reversi.save

Where a save goes when nobody has said.

=head2 command

    my ($is_save, $file) = Game::Terminal::Kit::Save::command($typed);

For a game that is typed at: whether a typed line is C<save> or C<save
FILE>, and the file if one was given. An empty list when it is not.

=head2 game_keys

C<S> for save, as a hash reference for a picker. Capital, because C<s>
already means something in some of the games.

=head2 ask_file

    my $path = Game::Terminal::Kit::Save::ask_file($keys, $screen, default => 'reversi.save');

Asks where to save, with the default already typed: a
L<Game::Terminal::Kit::Line> when the keys are raw, and a typed line when
they are not, where an empty answer takes the default. Undef when the person
backs out. C<prompt> and C<head> may be given.

=head1 SEE ALSO

L<Game::Terminal::Kit::History>, L<Game::Terminal::Kit::Replay>.

=head1 AUTHOR

LNATION, C<< <email at lnation.org> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by LNATION.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
