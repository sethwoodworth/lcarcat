"""Shortening a label so it still reads when it will not fit.

A block-letter title costs about two columns per character, so on a narrow bar
the choice is not "label or no label" but "which shorter label". LCARS panels
abbreviate rather than truncate -- the reference screens are full of clipped
words that are clipped *deliberately*, at the vowels, and never with an
ellipsis, which is a typographic mark LCARS does not use.

The ladder, widest first:

    PULL REQUESTS  ->  PLL RQSTS  ->  PR

``fit`` tries each rung and returns the first that fits, so a wide bar keeps
the full words and a narrow one keeps an initialism.
"""
from __future__ import annotations

from typing import Callable, Iterator, Optional

VOWELS = "AEIOU"


def disemvowel(text: str) -> str:
    """Drop interior vowels, keeping each word's first and last letter.

    Keeping the last letter matters: ``STATUS`` -> ``STTS`` still reads, while
    ``STT`` reads as an unrelated abbreviation. A word of three letters or
    fewer is left alone -- there is nothing to take out of ``SKY`` that leaves
    it a word.
    """
    words = []
    for word in text.split():
        if len(word) <= 3:
            words.append(word)
            continue
        body = "".join(character for character in word[1:-1]
                       if character.upper() not in VOWELS)
        words.append(word[0] + body + word[-1])
    return " ".join(words)


def initials(text: str) -> str:
    """First letters of the words: ``PULL REQUESTS`` -> ``PR``.

    A single word keeps its first three letters instead, because one letter is
    not a label.
    """
    words = text.split()
    if len(words) == 1:
        return words[0][:3]
    return "".join(word[0] for word in words if word)


def ladder(text: str) -> Iterator[str]:
    """The candidate labels, widest first, each distinct from the last."""
    seen = set()
    for candidate in (text, disemvowel(text), initials(text)):
        candidate = candidate.strip()
        if candidate and candidate not in seen:
            seen.add(candidate)
            yield candidate


def fit(text: str, width_of: Callable[[str], int], available: int) -> Optional[str]:
    """The widest candidate that fits ``available``, or None if none does.

    ``width_of`` is whatever measures the label in the medium being drawn --
    cell columns for text, image columns for block letters.
    """
    for candidate in ladder(text):
        if width_of(candidate) <= available:
            return candidate
    return None
