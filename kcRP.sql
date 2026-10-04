-- --------------------------------------------------------
-- Hôte:                         127.0.0.1
-- Version du serveur:           10.4.32-MariaDB - mariadb.org binary distribution
-- SE du serveur:                Win64
-- HeidiSQL Version:             12.11.0.7065
-- --------------------------------------------------------

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET NAMES utf8 */;
/*!50503 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

-- Listage des données de la table kcrp.bank_transactions : ~2 rows (environ)
INSERT INTO `bank_transactions` (`id`, `character_id`, `account_name`, `amount`, `balance_after`, `reason`, `from_character_id`, `to_character_id`, `created_at`) VALUES
	(1, 1, 'bank', 2000, 2000, 'bank deposit', NULL, 1, '2026-10-02T18:03:56Z'),
	(2, 1, 'bank', -25, 1975, 'bank withdrawal', 1, NULL, '2026-10-02T18:04:11Z');

-- Listage des données de la table kcrp.companies : ~1 rows (environ)
INSERT INTO `companies` (`id`, `code`, `label`, `job_name`, `level_name`, `owner_character_id`, `bank_balance`, `active`, `created_at`, `updated_at`) VALUES
	(1, 'blacksmith_kuttenberg', 'Forge de Kuttenberg', 'blacksmith', 'kutnohorsko', 1, 0, 1, '2026-10-03T05:14:51Z', '2026-10-03T16:57:54Z');

-- Listage des données de la table kcrp.company_logs : ~1 rows (environ)
INSERT INTO `company_logs` (`id`, `company_id`, `character_id`, `action`, `details`, `created_at`) VALUES
	(1, 1, 1, 'owner_assigned', 'first owner assigned', '2026-10-03T05:25:11Z');

-- Listage des données de la table kcrp.company_members : ~1 rows (environ)
INSERT INTO `company_members` (`company_id`, `character_id`, `role`, `active`, `assigned_by_character_id`, `joined_at`, `updated_at`) VALUES
	(1, 1, 'owner', 1, 1, '2026-10-03T05:25:11Z', '2026-10-03T05:25:11Z');

-- Listage des données de la table kcrp.company_properties : ~1 rows (environ)
INSERT INTO `company_properties` (`id`, `company_id`, `property_type`, `level_name`, `label`, `door_key`, `stash_key`, `burglary_allowed`, `active`, `created_at`, `updated_at`) VALUES
	(1, 1, 'workshop', 'kutnohorsko', 'Atelier de la Forge de Kuttenberg', 'door.workshop_a1', 'chest.smithy_workshop2', 1, 1, '2026-10-03T05:14:51Z', '2026-10-03T05:14:51Z');

-- Listage des données de la table kcrp.horse_items : ~0 rows (environ)

-- Listage des données de la table kcrp.horse_stats : ~0 rows (environ)

-- Listage des données de la table kcrp.players : ~1 rows (environ)
INSERT INTO `players` (`id`, `name`, `password`, `visits`, `x`, `y`, `z`, `yaw`, `money`, `level`, `look`, `nourishment`, `energy`, `last_seen`) VALUES
	(1, 'frgusnn', 'pbkdf2$20000$Ha4srMONJm6KDKJ+SM67rA==$GW8ZIYZv3n7ctw9lTYDkHLd38dORdYYWljQqEJeY5SY=', 59, 809.5499877929688, 3362.889892578125, 141.4499969482422, 258.134765625, 1223, 'kutnohorsko', 'body=m_body_roma_02;head=m_head_044;hair=m_hair_006_black;beard=m_beard_13', 0, 5.479921, '2026-10-03T16:57:10Z');

-- Listage des données de la table kcrp.player_accounts : ~1 rows (environ)
INSERT INTO `player_accounts` (`player_id`, `account_name`, `balance`, `updated_at`) VALUES
	(1, 'bank', 1975, '2026-10-03T16:57:10Z');

-- Listage des données de la table kcrp.player_horses : ~0 rows (environ)

-- Listage des données de la table kcrp.player_items : ~1 rows (environ)
INSERT INTO `player_items` (`player_id`, `slot`, `item`, `item_name`, `amount`, `health`, `worn`) VALUES
	(1, 1, 'torch_weapon', NULL, 3, 100, 0);

-- Listage des données de la table kcrp.player_jobs : ~1 rows (environ)
INSERT INTO `player_jobs` (`player_id`, `job_name`, `grade_level`, `onduty`, `updated_at`) VALUES
	(1, 'blacksmith', 2, 0, '2026-10-03T16:57:10Z');

-- Listage des données de la table kcrp.player_perks : ~36 rows (environ)
INSERT INTO `player_perks` (`player_id`, `perk`) VALUES
	(1, '0856ace1-3956-4cec-8283-f3c5374f5d1a'),
	(1, '1627a1b6-64c5-422f-ac2d-3a6abc071690'),
	(1, '1ba52d97-abef-4e36-8d2f-71d4a3c61123'),
	(1, '2993585c-40c9-42e3-ac45-b837f3bc50f7'),
	(1, '2ccea5e0-5a8d-4c48-b219-79554b377d9e'),
	(1, '2f446df8-79ba-4f94-93f3-d679a670e025'),
	(1, '4029a057-492c-4b6c-9a47-1616bc658f81'),
	(1, '46f3ea9c-2564-4801-99d4-8ac2d8903ff0'),
	(1, '47709bf7-3bd8-493f-aca3-05b005f166d8'),
	(1, '4c9a9491-cb87-46c4-985b-f37f1a2b2501'),
	(1, '4cfff8f5-85ad-48d2-b8d1-e03fff06bc02'),
	(1, '4cfff8f5-85ad-48d2-b8d1-e03fff06bc03'),
	(1, '4cfff8f5-85ad-48d2-b8d1-e03fff06bcd0'),
	(1, '4cfff8f5-85ad-48d2-b8d1-e03fff06bcd1'),
	(1, '4e2c4279-6b16-4a62-8ff2-3e989c6f8946'),
	(1, '636f75c0-8f7e-4942-8928-4e1a84d79298'),
	(1, '6e91b970-4ab6-47ca-bed1-edb962261076'),
	(1, '70aa202d-c0ed-49f6-94df-21cc1cda7a42'),
	(1, '734c075b-5354-4a72-b35c-21efa9c938cb'),
	(1, '76e6a383-9a9c-4e87-a75c-e4c968833d5f'),
	(1, '7a920bbd-fda0-4027-bcd4-43a3b9042ad5'),
	(1, '7c804de3-ed00-4cd3-aa99-4220a66c7036'),
	(1, '91208236-3b09-4918-9ee2-95c4a3bc52c4'),
	(1, '91bb2d0e-dfff-4ead-9c4b-cd79702115bc'),
	(1, '9930a43e-789a-41ad-8396-b5ee0c3e7a78'),
	(1, '9babbe52-36cb-455d-b36c-2b4d8d21c722'),
	(1, 'b4c56e39-f13b-4b2a-b0aa-0ceda4d7e727'),
	(1, 'bc29793d-4f74-40a3-9c0f-4f5d81821f56'),
	(1, 'c63bd90e-bd62-40e9-9bb4-8736f9a38e13'),
	(1, 'd2da2217-d46d-4cdb-accb-4ff860a3d83e'),
	(1, 'dc744495-333c-458b-88b8-a4fbd5efcc67'),
	(1, 'e1256788-29bd-4265-b055-a1df6cd9160d'),
	(1, 'e2c65107-48dc-451b-b3b4-cbdc3a1b869c'),
	(1, 'e47198f9-6710-4513-b7ac-43e01288e3dd'),
	(1, 'eaf706c8-e8f8-4175-81de-b1c1dec4e2ba'),
	(1, 'ec4c5274-50e3-4bbf-9220-823b080647c4');

-- Listage des données de la table kcrp.player_progress : ~37 rows (environ)
INSERT INTO `player_progress` (`player_id`, `kind`, `name`, `level`, `xp`, `points`) VALUES
	(1, 'skill', 'alchemy', 5, 0, 0),
	(1, 'skill', 'armourer', 0, 0, 0),
	(1, 'skill', 'bard', 0, 0, 0),
	(1, 'skill', 'bowyery', 0, 0, 0),
	(1, 'skill', 'cooking', 0, 0, 0),
	(1, 'skill', 'craftsmanship', 5, 0, 0),
	(1, 'skill', 'defense', 5, 0, 0),
	(1, 'skill', 'drinking', 5, 0, 0),
	(1, 'skill', 'fencing', 5, 3.75, 0),
	(1, 'skill', 'first_aid', 0, 0, 0),
	(1, 'skill', 'fishing', 0, 0, 0),
	(1, 'skill', 'gambling', 0, 0, 0),
	(1, 'skill', 'gunsmithing', 0, 0, 0),
	(1, 'skill', 'heavy_weapons', 5, 0, 0),
	(1, 'skill', 'horse_riding', 5, 0, 0),
	(1, 'skill', 'houndmaster', 5, 0, 0),
	(1, 'skill', 'marksmanship', 5, 0, 0),
	(1, 'skill', 'mining', 0, 0, 0),
	(1, 'skill', 'scholarship', 5, 0, 0),
	(1, 'skill', 'shoemaking', 0, 0, 0),
	(1, 'skill', 'stealth', 5, 0, 0),
	(1, 'skill', 'survival', 6, 200, 1),
	(1, 'skill', 'tailoring', 0, 0, 0),
	(1, 'skill', 'thievery', 5, 0, 0),
	(1, 'skill', 'weapon_dagger', 0, 0, 0),
	(1, 'skill', 'weapon_large', 5, 0, 0),
	(1, 'skill', 'weapon_shield', 0, 0, 0),
	(1, 'skill', 'weapon_sword', 5, 0, 0),
	(1, 'skill', 'weapon_unarmed', 5, 6, 0),
	(1, 'skill', 'weaponsmithing', 0, 0, 0),
	(1, 'stat', 'agility', 5, 6, 0),
	(1, 'stat', 'mainlevel', 5, 0, 0),
	(1, 'stat', 'prestige', 0, 0, 0),
	(1, 'stat', 'speech', 5, 0, 0),
	(1, 'stat', 'storyprogress', 5, 0, 0),
	(1, 'stat', 'strength', 5, 12, 0),
	(1, 'stat', 'vitality', 5, 89, 0);

/*!40103 SET TIME_ZONE=IFNULL(@OLD_TIME_ZONE, 'system') */;
/*!40101 SET SQL_MODE=IFNULL(@OLD_SQL_MODE, '') */;
/*!40014 SET FOREIGN_KEY_CHECKS=IFNULL(@OLD_FOREIGN_KEY_CHECKS, 1) */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40111 SET SQL_NOTES=IFNULL(@OLD_SQL_NOTES, 1) */;
