import { describe, expect, it } from 'vitest'
import { overall } from '../src/used'
import { TEAMS } from './helpers'

describe('overall', () => {
  it('numbers round 2 slot 1 after the first round', () => {
    expect(overall({ round: 2, slot: 1 }, TEAMS)).toBe(5)
  })
})
