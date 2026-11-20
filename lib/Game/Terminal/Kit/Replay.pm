package Game::Terminal::Kit::Replay;

use 5.014;
use strict;
use warnings;

use Carp ();
use Object::Proto::Sugar -types;
use Game::Terminal::Kit::Widget;

our $VERSION = '0.06';

has steps => (
	is => 'rw',
	isa => ArrayRef
);

has [qw/load draw/] => (
	is => 'rw',
	isa => CodeRef
);

has [qw/head legend/] => (
	is => 'rw',
	isa => ArrayRef
);

has at => (
	is => 'rw',
	isa => Int,
	default => 0
);

has mark => (
	is => 'rw',
	isa => Int
);

has pace => (
	is => 'rw',
	default => 1
);

has playing => (
	is => 'rw',
	isa => Bool,
	default => 0
);

has [qw/save screen log/] => (
	is => 'rw'
);

has _games => (
	is => 'rw',
	isa => HashRef,
	private => 1
);

sub BUILD {
	my ($self) = @_;
	if (my $save = $self->save) {
		$self->steps([ $save->steps ]) unless $self->steps;
		$self->mark($save->at) unless defined $self->mark;
	}
	Carp::croak('Game::Terminal::Kit::Replay: steps, or a save, are needed')
		unless ref $self->steps eq 'ARRAY' && @{ $self->steps };
	Carp::croak('Game::Terminal::Kit::Replay: load and draw are both needed')
		unless $self->load && $self->draw;
	Carp::croak('Game::Terminal::Kit::Replay: the pace is not a number of seconds')
		unless $self->pace =~ m/\A(?:\d+\.?\d*|\.\d+)\z/;
	$self->mark($#{ $self->steps }) unless defined $self->mark;
	$self->head([]) unless $self->head;
	$self->legend([ 'left and right step, home and end go to either end, space plays,',
		'enter plays on from here, q stops' ]) unless $self->legend;
	$self->_games({});
	$self->at(0) unless $self->at >= 0 && $self->at <= $#{ $self->steps };
	return $self;
}

sub count {
	my ($self) = @_;
	return scalar @{ $self->steps };
}

sub game {
	my ($self, $index) = @_;
	$index = $self->at unless defined $index;
	my $games = $self->_games;
	return $games->{$index} if exists $games->{$index};
	my $text = $self->steps->[$index];
	Carp::croak("Game::Terminal::Kit::Replay: there is no step $index") unless defined $text;
	my $game = $self->load->($text);
	Carp::croak("Game::Terminal::Kit::Replay: load gave nothing back for step " . ($index + 1))
		unless defined $game;
	return $games->{$index} = $game;
}

sub status {
	my ($self) = @_;
	my ($at, $mark) = ($self->at, $self->mark);
	return sprintf('step %d of %d', $at + 1, $self->count)
		. ($at == $mark ? ', where it was saved' : $at > $mark ? ', undone before it was saved' : '')
		. ($self->playing ? ', playing' : '');
}

sub frame {
	my ($self) = @_;
	my @board = eval { $self->draw->($self->game, $self) };
	unless (@board) {
		my $why = $@ || 'draw gave back nothing';
		$why =~ s/ at \S+ line \d+\.?\n?\z//;
		$why =~ s/\AGame::Terminal::Kit::\w+: //;
		chomp $why;
		@board = ("step " . ($self->at + 1) . " cannot be shown: $why");
	}
	return (@board, '', $self->status);
}

sub lines {
	my ($self) = @_;
	my @said = $self->log ? $self->log->lines : ();
	return (@{ $self->head }, $self->frame, (@said ? ('', @said) : ()),
		map { Game::Terminal::Kit::Widget::paint($self, $_, '2') } @{ $self->legend });
}

sub go {
	my ($self, $index) = @_;
	my $last = $#{ $self->steps };
	$index = 0 if $index < 0;
	$index = $last if $index > $last;
	return ('none') if $index == $self->at;
	$self->at($index);
	return ('moved');
}

sub tick {
	my ($self) = @_;
	return ('none') unless $self->playing;
	my @event = $self->go($self->at + 1);
	$self->playing(0) if $self->at == $#{ $self->steps };
	return @event;
}

sub step {
	my ($self, $key) = @_;
	return ('quit') if !defined $key || $key eq 'eof' || $key eq 'interrupt' || $key eq 'q' || $key eq 'escape';
	return $self->go($self->at - 1) if $key eq 'left' || $key eq 'up' || $key eq 'back_tab' || $key eq 'backspace';
	return $self->go($self->at + 1) if $key eq 'right' || $key eq 'down' || $key eq 'tab';
	return $self->go(0) if $key eq 'home' || $key eq 'page_up';
	return $self->go($#{ $self->steps }) if $key eq 'end' || $key eq 'page_down';
	return ('chosen', $self->at) if $key eq 'enter';
	if ($key eq ' ') {
		if ($self->playing) {
			$self->playing(0);
		} else {
			$self->at(0) if $self->at == $#{ $self->steps };
			$self->playing(1);
		}
		return ('changed');
	}
	$self->log->note('That key does nothing here.') if $self->log;
	return ('none');
}

sub run {
	my ($self, $keys, $screen) = @_;
	while (1) {
		Game::Terminal::Kit::Widget::draw($self, $screen);
		my $key = $keys->read_key($self->playing ? $self->pace : undef);
		if (!defined $key) {
			return ('quit') unless $self->playing;
			$self->tick;
			next;
		}
		my ($event, $value) = $self->step($key);
		next if Game::Terminal::Kit::Widget::goes_on($event);
		return $event eq 'chosen' ? ($event, $value) : ($event);
	}
}

sub play {
	my ($self, $keys, $screen) = @_;
	my $was_raw = $keys->raw;
	if ($was_raw || $keys->enter_raw) {
		$screen->hide_cursor;
		my @result = eval { $self->run($keys, $screen) };
		my $died = $@;
		$screen->show_cursor;
		$keys->leave_raw unless $was_raw;
		die $died unless @result;
		return @result;
	}
	my $was = $self->at;
	for my $index (0 .. $#{ $self->steps }) {
		$self->at($index);
		$screen->say(@{ $self->head }) if $index == 0 && @{ $self->head };
		$screen->say($self->frame, '');
	}
	$self->at($was);
	return ('quit');
}

1;

__END__

=head1 NAME

Game::Terminal::Kit::Replay - a saved game, watched a step at a time

=head1 VERSION

Version 0.06

=head1 SYNOPSIS

    use Game::Terminal::Kit::Replay;
    use Game::Terminal::Kit::Save;

    my $save = Game::Terminal::Kit::Save->read_file($path, game => 'reversi');
    my $replay = Game::Terminal::Kit::Replay->new(
        save => $save,
        load => sub { Game::Reversi->from_text($_[0]) },
        draw => sub { my ($game, $replay) = @_; $terminal->board_text($game) },
        head => [ 'reversi, saved ' . $save->saved_at ],
    );

    my ($event, $step) = $replay->play($keys, $screen);
    if ($event eq 'chosen') {
        # play on from the step shown: undo reaches the steps before it,
        # and redo the ones after
        $terminal->game($history->resume($save->from_step($step)));
        $terminal->start;
    }

=head1 DESCRIPTION

The steps of a L<Game::Terminal::Kit::Save>, shown one at a time: each is
built with C<load> and drawn with C<draw>, the game's own board. A step is
what L<Game::Terminal::Kit::History> kept: a game played against the
program has one for each of the person's turns, with the program's reply,
and a game two people play at one keyboard has one for each move.

All of them are shown, the ones undone before the game was saved included,
and the line under the board says which step is the one it was saved at and
which were undone.

It is a widget, as L<Game::Terminal::Kit::Widget> describes: L</lines> and
L</step> touch nothing but the replay, so a test needs no terminal.

=head2 Keys

    left, up            a step back
    right, down         a step on
    home, end           the first step, the last
    space               play the steps on their own, or stop; from the
                        last, start again at the first
    enter               play on from this step: the event is chosen, and
                        its value the step's index
    q, escape           stop

=head1 ATTRIBUTES

=head2 save

A L<Game::Terminal::Kit::Save>, from which C<steps> and C<mark> are taken
when they are not given.

=head2 steps

The steps as strings, oldest first. Needed, or C<save>.

=head2 load

A code reference given a step and returning a game. Needed. A game is built
once for each step shown, and kept.

=head2 draw

A code reference given a game and the replay, returning the lines of the
board. Needed. A C<draw> that dies is shown as a line saying so, in place of
the board, so one step that cannot be read does not end the replay.

=head2 at

The index of the step shown; the first, 0, to begin with.

=head2 mark

The index of the step the game was saved at; the steps after it were
undone. The last step, unless the save says.

=head2 pace

Seconds between steps while playing; 1 by default. A fraction will do.

=head2 playing

True while the steps go on by themselves.

=head2 head

=head2 legend

Lines above the board, and below it. The legend names the keys unless one
is given.

=head2 screen

=head2 log

As for every widget: a screen to paint with, and a
L<Game::Terminal::Kit::Log> whose lines are drawn under the board.

=head1 METHODS

=head2 lines

=head2 step

=head2 run

As L<Game::Terminal::Kit::Widget> has them. C<run> reads with a timeout
while playing, and moves on a step when none comes. Its events are C<quit>,
and C<chosen> with the index of the step shown.

=head2 play

    my ($event, $index) = $replay->play($keys, $screen);

The whole of a replay. On a terminal the keys are made raw and the cursor
hidden for as long as L</run> takes, and both put back. Off a terminal, with
no keys to step with, every step is written out in turn, each with its line
saying where it is, and the event is C<quit>: so a replay can go to a file.

=head2 frame

The board for the step shown, with the line that says which it is.

=head2 status

That line: C<step 3 of 12>, and whether it is where the game was saved,
undone before it was, or playing.

=head2 game

    my $game = $replay->game;
    my $game = $replay->game($index);

The game at the step shown, or at an index, built by C<load>.

=head2 count

How many steps there are.

=head2 go

    $replay->go($index);

Shows a step, the nearest there is. C<moved>, or C<none> when it was
already shown.

=head2 tick

A step on, while playing; playing stops at the last step.

=head1 SEE ALSO

L<Game::Terminal::Kit::Save>, L<Game::Terminal::Kit::History>,
L<Game::Terminal::Kit::Widget>.

=head1 AUTHOR

LNATION, C<< <email at lnation.org> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by LNATION.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
