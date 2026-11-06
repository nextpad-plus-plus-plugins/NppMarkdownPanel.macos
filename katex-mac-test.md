# KaTeX Mac smoke test

## Basics
Inline: $E=mc^2$

Display:
$$
\int_0^1 x\,dx = \tfrac{1}{2}
$$

Also: \(a^2+b^2=c^2\) and
\[
\sum_{n=1}^{N} n = \frac{N(N+1)}{2}
\]

## Currency (should NOT be math)
Costs $5 and $10 today.

## Escaped dollars
Not math: \$x\$ and price \$12.

## Inside formula
Literal dollar: $\$5$   vs   $x=\$y$

## Markdown stress
Bold math: **$a*b*c$**

Link with dollars in URL (should stay a normal link): [x](https://example.com/$a$/$b$)

## Code (math must stay literal)
Inline: `$x$`

Fence:
```
$E=mc^2$
```

Four-backtick fence with inner triple:
````
```
$inner$
```
````

Blockquote fence:
> ```
> $x$
> ```

## After fence
```
code
```

$E=mc^2$ after a fence.
