package main
import "core:mem"

import "core:fmt"
import sqlite "../../../../sqlite"

print_balance :: proc(db: sqlite.DB, label: string, account_id: i64) {
	stmt, err, ok := sqlite.stmt_prepare(
		db,
		"SELECT owner_name, balance_cents FROM accounts WHERE id = ?1",
	)
	if !ok {
		fmt.println("prepare balance query failed:", sqlite.error_string(err))
		return
	}
	defer sqlite.stmt_finalize(&stmt)

	err, ok = sqlite.stmt_bind_i64(&stmt, 1, account_id)
	if !ok {
		fmt.println("bind balance query failed:", sqlite.error_string(err))
		return
	}

	has_row, step_err, step_ok := sqlite.stmt_next(stmt)
	if !step_ok {
		fmt.println("step balance query failed:", sqlite.error_string(step_err))
		return
	}
	if !has_row {
		fmt.printf("%s account_id=%d not found\n", label, account_id)
		return
	}

	owner_name := sqlite.stmt_get_text(stmt, 0, context.temp_allocator)
	balance := sqlite.stmt_get_i64(stmt, 1)

	fmt.printf(
		"%s account_id=%d owner=%q balance_cents=%d\n",
		label,
		account_id,
		owner_name,
		balance,
	)
}

main :: proc() {
	tracking_allocator: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking_allocator, context.allocator)
	context.allocator = mem.tracking_allocator(&tracking_allocator)
	defer {
		if len(tracking_allocator.allocation_map) > 0 {
			fmt.eprintf("=== %v allocations not freed: ===\n", len(tracking_allocator.allocation_map))
			for _, entry in tracking_allocator.allocation_map {
				fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
			}
		}
		if len(tracking_allocator.bad_free_array) > 0 {
			fmt.eprintf("=== %v incorrect frees: ===\n", len(tracking_allocator.bad_free_array))
			for entry in tracking_allocator.bad_free_array {
				fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
			}
		}
		mem.tracking_allocator_destroy(&tracking_allocator)
	}

	db, err, ok := sqlite.db_open(":memory:")
	if !ok {
		fmt.println("open failed:", sqlite.error_string(err))
		return
	}
	defer sqlite.db_close(&db)

	err, ok = sqlite.db_exec(db, `
		CREATE TABLE accounts(
			id            INTEGER PRIMARY KEY,
			owner_name    TEXT NOT NULL,
			balance_cents INTEGER NOT NULL
		);
	`)
	if !ok {
		fmt.println("create table failed:", sqlite.error_string(err))
		return
	}

	err, ok = sqlite.db_exec(db, `
		INSERT INTO accounts(owner_name, balance_cents) VALUES
			('Alice', 10000),
			('Bob',    2500);
	`)
	if !ok {
		fmt.println("seed insert failed:", sqlite.error_string(err))
		return
	}

	print_balance(db, "initial", 1)
	print_balance(db, "initial", 2)

	fmt.println("")
	fmt.println("== committed transfer ==")

	err, ok = sqlite.db_begin(db)
	if !ok {
		fmt.println("begin transaction failed:", sqlite.error_string(err))
		return
	}

	err, ok = sqlite.db_exec(
		db,
		"UPDATE accounts SET balance_cents = balance_cents - 1500 WHERE id = 1",
	)
	if !ok {
		fmt.println("debit inside transaction failed:", sqlite.error_string(err))
		_, _ = sqlite.db_rollback(db)
		return
	}

	err, ok = sqlite.db_exec(
		db,
		"UPDATE accounts SET balance_cents = balance_cents + 1500 WHERE id = 2",
	)
	if !ok {
		fmt.println("credit inside transaction failed:", sqlite.error_string(err))
		_, _ = sqlite.db_rollback(db)
		return
	}

	err, ok = sqlite.db_commit(db)
	if !ok {
		fmt.println("commit failed:", sqlite.error_string(err))
		return
	}

	print_balance(db, "after committed transfer", 1)
	print_balance(db, "after committed transfer", 2)

	fmt.println("")
	fmt.println("== rolled back transfer ==")

	err, ok = sqlite.db_begin_immediate(db)
	if !ok {
		fmt.println("begin immediate transaction failed:", sqlite.error_string(err))
		return
	}

	err, ok = sqlite.db_exec(
		db,
		"UPDATE accounts SET balance_cents = balance_cents - 9999 WHERE id = 1",
	)
	if !ok {
		fmt.println("debit for rollback example failed:", sqlite.error_string(err))
		_, _ = sqlite.db_rollback(db)
		return
	}

	err, ok = sqlite.db_exec(
		db,
		"UPDATE accounts SET balance_cents = balance_cents + 9999 WHERE id = 2",
	)
	if !ok {
		fmt.println("credit for rollback example failed:", sqlite.error_string(err))
		_, _ = sqlite.db_rollback(db)
		return
	}

	err, ok = sqlite.db_rollback(db)
	if !ok {
		fmt.println("rollback failed:", sqlite.error_string(err))
		return
	}

	print_balance(db, "after rollback", 1)
	print_balance(db, "after rollback", 2)

	fmt.println("")
	fmt.println("transaction commit and rollback example completed successfully")
}